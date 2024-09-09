pragma solidity 0.5.17;

import {Registry} from "../../common/Registry.sol";
import {ERC20NonTradable} from "../../common/tokens/ERC20NonTradable.sol";
import {ERC20} from "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import {StakingInfo} from "./../StakingInfo.sol";
import {EventsHub} from "./../EventsHub.sol";
import {OwnableLockable} from "../../common/mixin/OwnableLockable.sol";
import {IStakeManager} from "../stakeManager/IStakeManager.sol";
import {IValidatorShare} from "./IValidatorShare.sol";
import {Initializable} from "../../common/mixin/Initializable.sol";
import {IERC20Permit} from "./../../common/misc/IERC20Permit.sol";

contract ValidatorShare is IValidatorShare, ERC20NonTradable, OwnableLockable, Initializable {
    struct DelegatorUnbond {
        uint256 shares;
        uint256 withdrawEpoch;
    }

    uint256 constant EXCHANGE_RATE_PRECISION = 100;
    // maximum matic possible, even if rate will be 1 and all matic will be staked in one go, it will result in 10 ^ 58 shares
    uint256 constant EXCHANGE_RATE_HIGH_PRECISION = 10**29;
    uint256 constant MAX_COMMISION_RATE = 100;
    uint256 constant REWARD_PRECISION = 10**25;

    StakingInfo public stakingLogger;
    IStakeManager public stakeManager;
    uint256 public validatorId;
    uint256 public validatorRewards_deprecated;
    uint256 public commissionRate_deprecated;
    uint256 public lastCommissionUpdate_deprecated;
    uint256 public minAmount;

    uint256 public totalStake_deprecated;
    uint256 public rewardPerShare;
    uint256 public activeAmount;

    bool public delegation;

    uint256 public withdrawPool;
    uint256 public withdrawShares;

    mapping(address => uint256) amountStaked_deprecated; // deprecated, keep for foundation delegators
    mapping(address => DelegatorUnbond) public unbonds;
    mapping(address => uint256) public initalRewardPerShare;

    mapping(address => uint256) public unbondNonces;
    mapping(address => mapping(uint256 => DelegatorUnbond)) public unbonds_new;

    EventsHub public eventsHub;

    IERC20Permit public polToken;

    constructor() public {
        _disableInitializer();
    }

    // onlyOwner will prevent this contract from initializing, since it's owner is going to be 0x0 address
    function initialize(
        uint256 _validatorId,
        address _stakingLogger,
        address _stakeManager
    ) external initializer {
        validatorId = _validatorId;
        stakingLogger = StakingInfo(_stakingLogger);
        stakeManager = IStakeManager(_stakeManager);
        _transferOwnership(_stakeManager);
        _getOrCacheEventsHub();

        minAmount = 10**18;
        delegation = true;
    }

    /**
        Public View Methods
    */

    function exchangeRate() public view returns (uint256) {
        uint256 totalShares = totalSupply();
        uint256 precision = _getRatePrecision();
        return totalShares == 0 ? precision : stakeManager.delegatedAmount(validatorId).mul(precision).div(totalShares);
    }

    function getTotalStake(address user) public view returns (uint256, uint256) {
        uint256 shares = balanceOf(user);
        uint256 rate = exchangeRate();
        if (shares == 0) {
            return (0, rate);
        }

        return (rate.mul(shares).div(_getRatePrecision()), rate);
    }

    function withdrawExchangeRate() public view returns (uint256) {
        uint256 precision = _getRatePrecision();
        if (validatorId < 8) {
            // fix of potentially broken withdrawals for future unbonding
            // foundation validators have no slashing enabled and thus we can return default exchange rate
            // because without slashing rate will stay constant
            return precision;
        }

        uint256 _withdrawShares = withdrawShares;
        return _withdrawShares == 0 ? precision : withdrawPool.mul(precision).div(_withdrawShares);
    }

    function getLiquidRewards(address user) public view returns (uint256) {
        return _calculateReward(user, getRewardPerShare());
    }

    function getRewardPerShare() public view returns (uint256) {
        return _calculateRewardPerShareWithRewards(stakeManager.delegatorsReward(validatorId));
    }

    /**
        Public Methods
     */
    function buyVoucher(uint256 _amount, uint256 _minSharesToMint) public returns (uint256 amountToDeposit) {
        return _buyVoucher(_amount, _minSharesToMint, false);
    }

    // @dev permit only available on pol token
    // @dev txn fails if frontrun, use buyVoucher instead
    function buyVoucherWithPermit(
        uint256 _amount,
        uint256 _minSharesToMint,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public returns (uint256 amountToDeposit) {
        IERC20Permit _polToken = _getOrCachePOLToken();
        uint256 nonceBefore = _polToken.nonces(msg.sender);
        _polToken.permit(msg.sender, address(stakeManager), _amount, deadline, v, r, s);
        require(_polToken.nonces(msg.sender) == nonceBefore + 1, "Invalid permit");
        return _buyVoucher(_amount, _minSharesToMint, true); // invokes stakeManager to pull token from msg.sender
    }

    function buyVoucherPOL(uint256 _amount, uint256 _minSharesToMint) public returns (uint256 amountToDeposit) {
        return _buyVoucher(_amount, _minSharesToMint, true);
    }

    function _buyVoucher(uint256 _amount, uint256 _minSharesToMint, bool pol) internal returns (uint256 amountToDeposit) {
        _withdrawAndTransferReward(msg.sender, pol);

        amountToDeposit = _buyShares(_amount, _minSharesToMint, msg.sender);
        require(
            pol
                ? stakeManager.delegationDepositPOL(validatorId, amountToDeposit, msg.sender)
                : stakeManager.delegationDeposit(validatorId, amountToDeposit, msg.sender),
            "deposit failed"
        );

        return amountToDeposit;
    }

    function restake() public returns (uint256, uint256) {
        return _restake(false);
    }

    function restakePOL() public returns (uint256, uint256) {
        return _restake(true);
    }

    function _restake(bool pol) public returns (uint256, uint256) {
        address user = msg.sender;
        uint256 liquidReward = _withdrawReward(user);
        uint256 amountRestaked;

        require(liquidReward >= minAmount, "Too small rewards to restake");

        if (liquidReward != 0) {
            amountRestaked = _buyShares(liquidReward, 0, user);

            if (liquidReward > amountRestaked) {
                // return change to the user
                require(
                    pol
                        ? stakeManager.transferFundsPOL(validatorId, liquidReward - amountRestaked, user)
                        : stakeManager.transferFunds(validatorId, liquidReward - amountRestaked, user),
                    "Insufficent rewards"
                );
                stakingLogger.logDelegatorClaimRewards(validatorId, user, liquidReward - amountRestaked);
            }

            (uint256 totalStaked, ) = getTotalStake(user);
            stakingLogger.logDelegatorRestaked(validatorId, user, totalStaked);
        }
        
        return (amountRestaked, liquidReward);
    }

    function sellVoucher(uint256 claimAmount, uint256 maximumSharesToBurn) public {
        __sellVoucher(claimAmount, maximumSharesToBurn, false);
    }

    function sellVoucherPOL(uint256 claimAmount, uint256 maximumSharesToBurn) public {
        __sellVoucher(claimAmount, maximumSharesToBurn, true);
    }

    function __sellVoucher(uint256 claimAmount, uint256 maximumSharesToBurn, bool pol) internal {
        (uint256 shares, uint256 _withdrawPoolShare) = _sellVoucher(claimAmount, maximumSharesToBurn, pol);

        DelegatorUnbond memory unbond = unbonds[msg.sender];
        unbond.shares = unbond.shares.add(_withdrawPoolShare);
        // refresh unbond period
        unbond.withdrawEpoch = stakeManager.epoch();
        unbonds[msg.sender] = unbond;

        StakingInfo logger = stakingLogger;
        logger.logShareBurned(validatorId, msg.sender, claimAmount, shares);
        logger.logStakeUpdate(validatorId);
    }

    function withdrawRewards() public {
        _withdrawRewards(false);
    }

    function withdrawRewardsPOL() public {
        _withdrawRewards(true);
    }

    function _withdrawRewards(bool pol) internal {
        uint256 rewards = _withdrawAndTransferReward(msg.sender, pol);
        require(rewards >= minAmount, "Too small rewards amount");
    }

    function migrateOut(address user, uint256 amount) external onlyOwner {
        _withdrawAndTransferReward(user, true);
        (uint256 totalStaked, uint256 rate) = getTotalStake(user);
        require(totalStaked >= amount, "Migrating too much");

        uint256 precision = _getRatePrecision();
        uint256 shares = amount.mul(precision).div(rate);
        _burn(user, shares);

        stakeManager.updateValidatorState(validatorId, -int256(amount));
        activeAmount = activeAmount.sub(amount);

        stakingLogger.logShareBurned(validatorId, user, amount, shares);
        stakingLogger.logStakeUpdate(validatorId);
        stakingLogger.logDelegatorUnstaked(validatorId, user, amount);
    }

    function migrateIn(address user, uint256 amount) external onlyOwner {
        _withdrawAndTransferReward(user, true);
        _buyShares(amount, 0, user);
    } 

    function unstakeClaimTokens() public {
        _unstakeClaimTokens(false);
    }

    function unstakeClaimTokensPOL() public {
        _unstakeClaimTokens(true);
    }

    function _unstakeClaimTokens(bool pol) internal {
        DelegatorUnbond memory unbond = unbonds[msg.sender];
        uint256 amount = _unstakeClaimTokens(unbond, pol);
        delete unbonds[msg.sender];
        stakingLogger.logDelegatorUnstaked(validatorId, msg.sender, amount);
    }

    function slash(
        uint256 validatorStake,
        uint256 delegatedAmount,
        uint256 totalAmountToSlash
    ) external onlyOwner returns (uint256) {
        revert("Slashing disabled");
    }

    function updateDelegation(bool _delegation) external onlyOwner {
        delegation = _delegation;
    }

    function drain(
        address token,
        address payable destination,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0x0)) {
            destination.transfer(amount);
        } else {
            require(ERC20(token).transfer(destination, amount), "Drain failed");
        }
    }

    /**
        New shares exit API
     */
    function sellVoucher_new(uint256 claimAmount, uint256 maximumSharesToBurn) public {
        _sellVoucher_new(claimAmount, maximumSharesToBurn, false);
    }

    function sellVoucher_newPOL(uint256 claimAmount, uint256 maximumSharesToBurn) public {
        _sellVoucher_new(claimAmount, maximumSharesToBurn, true);
    }

    function _sellVoucher_new(uint256 claimAmount, uint256 maximumSharesToBurn, bool pol) public {
        (uint256 shares, uint256 _withdrawPoolShare) = _sellVoucher(claimAmount, maximumSharesToBurn, pol);

        uint256 unbondNonce = unbondNonces[msg.sender].add(1);

        DelegatorUnbond memory unbond = DelegatorUnbond({
            shares: _withdrawPoolShare,
            withdrawEpoch: stakeManager.epoch()
        });
        unbonds_new[msg.sender][unbondNonce] = unbond;
        unbondNonces[msg.sender] = unbondNonce;

        _getOrCacheEventsHub().logShareBurnedWithId(validatorId, msg.sender, claimAmount, shares, unbondNonce);
        stakingLogger.logStakeUpdate(validatorId);
    }

    function unstakeClaimTokens_new(uint256 unbondNonce) public {
        _unstakeClaimTokens_new(unbondNonce, false);
    }

    function unstakeClaimTokens_newPOL(uint256 unbondNonce) public {
        _unstakeClaimTokens_new(unbondNonce, true);
    }

    function _unstakeClaimTokens_new(uint256 unbondNonce, bool pol) internal {
        DelegatorUnbond memory unbond = unbonds_new[msg.sender][unbondNonce];
        uint256 amount = _unstakeClaimTokens(unbond, pol);
        delete unbonds_new[msg.sender][unbondNonce];
        _getOrCacheEventsHub().logDelegatorUnstakedWithId(validatorId, msg.sender, amount, unbondNonce);
    }

    /**
        Private Methods
     */

    function _getOrCacheEventsHub() private returns(EventsHub) {
        EventsHub _eventsHub = eventsHub;
        if (_eventsHub == EventsHub(0x0)) {
            _eventsHub = EventsHub(Registry(stakeManager.getRegistry()).contractMap(keccak256("eventsHub")));
            eventsHub = _eventsHub;
        }
        return _eventsHub;
    }

    function _getOrCachePOLToken() private returns (IERC20Permit) {
        IERC20Permit _polToken = polToken;
        if (_polToken == IERC20Permit(0x0)) {
            _polToken = IERC20Permit(Registry(stakeManager.getRegistry()).contractMap(keccak256("pol")));
            require(_polToken != IERC20Permit(0x0), "unset");
            polToken = _polToken;
        }
        return _polToken;
    }

    function _sellVoucher(
        uint256 claimAmount,
        uint256 maximumSharesToBurn,
        bool pol
    ) private returns (uint256, uint256) {
        // first get how much staked in total and compare to target unstake amount
        (uint256 totalStaked, uint256 rate) = getTotalStake(msg.sender);
        require(totalStaked != 0 && totalStaked >= claimAmount, "Too much requested");

        // convert requested amount back to shares
        uint256 precision = _getRatePrecision();
        uint256 shares = claimAmount.mul(precision).div(rate);
        require(shares <= maximumSharesToBurn, "too much slippage");

        _withdrawAndTransferReward(msg.sender, pol);

        _burn(msg.sender, shares);
        stakeManager.updateValidatorState(validatorId, -int256(claimAmount));
        activeAmount = activeAmount.sub(claimAmount);

        uint256 _withdrawPoolShare = claimAmount.mul(precision).div(withdrawExchangeRate());
        withdrawPool = withdrawPool.add(claimAmount);
        withdrawShares = withdrawShares.add(_withdrawPoolShare);

        return (shares, _withdrawPoolShare);
    }

    function _unstakeClaimTokens(DelegatorUnbond memory unbond, bool pol) private returns (uint256) {
        uint256 shares = unbond.shares;
        require(
            unbond.withdrawEpoch.add(stakeManager.withdrawalDelay()) <= stakeManager.epoch() && shares > 0,
            "Incomplete withdrawal period"
        );

        uint256 _amount = withdrawExchangeRate().mul(shares).div(_getRatePrecision());
        withdrawShares = withdrawShares.sub(shares);
        withdrawPool = withdrawPool.sub(_amount);

        require(
            pol ? stakeManager.transferFundsPOL(validatorId, _amount, msg.sender) : stakeManager.transferFunds(validatorId, _amount, msg.sender),
            "Insufficent rewards"
        );

        return _amount;
    }

    function _getRatePrecision() private view returns (uint256) {
        // if foundation validator, use old precision
        if (validatorId < 8) {
            return EXCHANGE_RATE_PRECISION;
        }

        return EXCHANGE_RATE_HIGH_PRECISION;
    }

    function _calculateRewardPerShareWithRewards(uint256 accumulatedReward) private view returns (uint256) {
        uint256 _rewardPerShare = rewardPerShare;
        if (accumulatedReward != 0) {
            uint256 totalShares = totalSupply();
            
            if (totalShares != 0) {
                _rewardPerShare = _rewardPerShare.add(accumulatedReward.mul(REWARD_PRECISION).div(totalShares));
            }
        }

        return _rewardPerShare;
    }

    function _calculateReward(address user, uint256 _rewardPerShare) private view returns (uint256) {
        uint256 shares = balanceOf(user);
        if (shares == 0) {
            return 0;
        }

        uint256 _initialRewardPerShare = initalRewardPerShare[user];

        if (_initialRewardPerShare == _rewardPerShare) {
            return 0;
        }

        return _rewardPerShare.sub(_initialRewardPerShare).mul(shares).div(REWARD_PRECISION);
    }

    function _withdrawReward(address user) private returns (uint256) {
        uint256 _rewardPerShare = _calculateRewardPerShareWithRewards(
            stakeManager.withdrawDelegatorsReward(validatorId)
        );
        uint256 liquidRewards = _calculateReward(user, _rewardPerShare);
        
        rewardPerShare = _rewardPerShare;
        initalRewardPerShare[user] = _rewardPerShare;
        return liquidRewards;
    }

    function _withdrawAndTransferReward(address user, bool pol) private returns (uint256) {
        uint256 liquidRewards = _withdrawReward(user);
        if (liquidRewards != 0) {
            require(
                pol ? stakeManager.transferFundsPOL(validatorId, liquidRewards, user) : stakeManager.transferFunds(validatorId, liquidRewards, user),
                "Insufficent rewards"
            );
            stakingLogger.logDelegatorClaimRewards(validatorId, user, liquidRewards);
        }
        return liquidRewards;
    }

    function _buyShares(
        uint256 _amount,
        uint256 _minSharesToMint,
        address user
    ) private onlyWhenUnlocked returns (uint256) {
        require(delegation, "Delegation is disabled");

        uint256 rate = exchangeRate();
        uint256 precision = _getRatePrecision();
        uint256 shares = _amount.mul(precision).div(rate);
        require(shares >= _minSharesToMint, "Too much slippage");
        require(unbonds[user].shares == 0, "Ongoing exit");

        _mint(user, shares);

        // clamp amount of tokens in case resulted shares requires less tokens than anticipated
        _amount = rate.mul(shares).div(precision);

        stakeManager.updateValidatorState(validatorId, int256(_amount));
        activeAmount = activeAmount.add(_amount);

        StakingInfo logger = stakingLogger;
        logger.logShareMinted(validatorId, user, _amount, shares);
        logger.logStakeUpdate(validatorId);

        return _amount;
    }

    function transferPOL(address to, uint256 value) public returns (bool) {
        _transfer(to, value, true);
        return true;
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(to, value, false);
        return true;
    }

    function _transfer(address to, uint256 value, bool pol) internal {
        address from = msg.sender;
        // get rewards for recipient
        _withdrawAndTransferReward(to, pol);
        // convert rewards to shares
        _withdrawAndTransferReward(from, pol);
        // move shares to recipient
        super._transfer(from, to, value);
        _getOrCacheEventsHub().logSharesTransfer(validatorId, from, to, value);
    }
}
