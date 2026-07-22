// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IVesting } from "./interfaces/IVesting.sol";

/// @title BotLocking
/// @notice Lock-and-reward contract with referral system and SVT bonus vesting.
/// @dev `paymentToken` is immutable and must be a standard non-fee, non-rebasing BEP-20 token
///      (e.g. BSC USDT) chosen by the trusted deployer. See `paymentToken` and the deploy checklist
///      in the project README before wiring a token address.
contract BotLocking is ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    error InvalidPlanIndex();
    error PlanAlreadyActivated();
    error PlanNotActivated();
    error InvalidAmount();
    error InvalidInvestmentIndex();
    error InvestmentLocked();
    error InvestmentAlreadyWithdrawn();
    error InvalidReferrer();
    error ReferralCirculationDetected();
    error NoReferralReward();
    error NoRewardsToClaim();
    error InsufficientFunds();
    error ZeroAddress();

    /// @notice Number of available investment plans.
    uint256 public constant PLAN_COUNT = 4;
    /// @notice Number of referral levels used by the referral system.
    uint256 public constant REF_LEVEL_COUNT = 7;
    /// @notice Basis points denominator (100% = 10_000).
    uint256 public constant PCT_BASE = 10000;
    /// @notice Number of seconds in the accounting month.
    uint256 public constant MONTH_IN_SECONDS = 30 days;
    /// @notice Number of seconds in the accounting year.
    uint256 public constant YEAR_IN_SECONDS = 365 days;
    /// @notice ERC20 token used for all contract payments.
    /// @dev Supported-token constraint: must be a standard BEP-20 with no transfer fees and no
    ///      rebasing. `invest()` and `deposit()` credit `contractTokenAmount` by the requested
    ///      `amount`, not by a post-transfer balance delta. Fee-on-transfer or rebasing tokens
    ///      would overstate internal liquidity and cause legitimate withdrawals to revert with
    ///      `InsufficientFunds`. Fixed at deploy to non-fee, non-rebasing BEP-20 USDT per the
    ///      trusted deployer model.
    IERC20Metadata public immutable paymentToken;
    /// @notice SVT vesting contract.
    IVesting public immutable svtVesting;
    /// @notice Provider wallet that receives plan activation/investment shares.
    address public immutable provider;
    /// @notice Developer wallet that receives withdrawal fee share.
    address public immutable developer;
    /// @notice Treasury wallet that receives undistributed referral shares.
    address public immutable treasury;

    /// @dev Contract liquid amount that can be used for direct withdrawals.
    uint256 public contractTokenAmount;

    /// @dev Static plan configuration.
    Plan[PLAN_COUNT] private _plans;
    /// @dev Activation referral shares by level (basis points).
    uint256[REF_LEVEL_COUNT] private _referralSystemActivationFeeShares;
    /// @dev Withdrawal reward referral shares by level (basis points).
    uint256[REF_LEVEL_COUNT] private _referralSystemRewardFeeShares;
    /// @dev SVT bonus referral shares by level (basis points).
    uint256[REF_LEVEL_COUNT] private _referralSystemSvtBonusFeeShares;

    /// @dev User investments by wallet.
    mapping(address => Investment[]) private _investments;
    /// @dev Participant/referral state by wallet.
    mapping(address => Participant) private _participants;

    /// @notice Investment plan configuration.
    struct Plan {
        /// @notice Lock duration for the plan in seconds.
        uint128 lockDuration;
        /// @notice Monthly return rate in basis points.
        uint64 monthlyReturnBps;
        /// @notice SVT bonus multiplier for the plan.
        uint64 svtBonusMultiplier;
        /// @notice One-time activation fee for the plan.
        uint256 activationFee;
    }

    /// @notice User investment position.
    struct Investment {
        /// @notice Principal amount locked by user.
        uint256 lockedAmount;
        /// @notice Timestamp when the investment was created.
        uint256 startTimestamp;
        /// @notice Plan index used for the investment.
        uint256 planIndex;
        /// @notice Claimed reward amount.
        uint256 claimedReward;
        /// @notice Whether the locked amount has been withdrawn.
        bool isLockedAmountWithdrawn;
    }

    /// @notice Aggregated participant and referral state.
    struct Participant {
        /// @notice Total principal currently locked across all investments.
        uint256 totalLockedAmount;
        /// @notice Activation flags per plan index.
        bool[PLAN_COUNT] isActive;
        /// @notice Registered referrer wallet.
        address referrer;
        /// @notice Unclaimed referral reward balance.
        uint256 referralSystemReward;
        /// @notice Referral counts by level.
        uint256[REF_LEVEL_COUNT] referralCounts;
        /// @notice Referral earnings by level.
        uint256[REF_LEVEL_COUNT] referralEarnings;
        /// @notice Whether the wallet has deposited liquidity into the contract.
        bool isDeposited;
    }

    /// @notice Emitted when a plan is activated by a wallet.
    /// @param wallet Activating wallet.
    /// @param index Activated plan index.
    event PlanActivated(address indexed wallet, uint256 indexed index);
    /// @notice Emitted when an investment is created.
    /// @param wallet Investor wallet.
    /// @param amount Invested amount.
    /// @param planIndex Target plan index.
    event InvestmentMade(address indexed wallet, uint256 amount, uint256 indexed planIndex);
    /// @notice Emitted when an investment is withdrawn.
    /// @param wallet Investor wallet.
    /// @param investmentIndex User investment index.
    /// @param lockedAmount Principal amount.
    /// @param reward Calculated gross reward amount.
    event InvestmentWithdrawn(address indexed wallet, uint256 indexed investmentIndex, uint256 lockedAmount, uint256 reward);
    /// @notice Emitted on final withdrawal distribution.
    /// @param wallet Receiver wallet.
    /// @param amount Principal amount.
    /// @param reward Net reward after reward fee.
    /// @param referralReward Referral reward amount.
    /// @param rewardFee Total reward fee charged from gross reward.
    event Withdraw(address indexed wallet, uint256 amount, uint256 reward, uint256 referralReward, uint256 rewardFee);
    /// @notice Emitted when referral fee is allocated to a referrer.
    /// @param referrer Referrer receiving referral allocation.
    /// @param referral User whose action generated referral fee.
    /// @param level Referral depth level.
    /// @param amount Allocated amount.
    event ReferralFeeDistributed(address indexed referrer, address indexed referral, uint256 indexed level, uint256 amount);
    /// @notice Emitted when a wallet registers a referrer.
    /// @param referral Wallet being referred.
    /// @param referrer Referrer wallet.
    event ReferrerRegistered(address indexed referral, address indexed referrer);
    /// @notice Emitted when accumulated referral reward is withdrawn.
    /// @param wallet Wallet that withdraws reward.
    /// @param amount Withdrawn reward amount.
    event ReferralRewardWithdrawn(address indexed wallet, uint256 amount);
    /// @notice Emitted when liquidity is deposited into the contract.
    /// @param wallet Depositor wallet.
    /// @param amount Deposited amount.
    event Deposited(address indexed wallet, uint256 amount);

    /// @notice Initializes token addresses, plan settings and referral shares.
    /// @param _paymentToken Standard non-fee, non-rebasing BEP-20 payment token (see `paymentToken`).
    /// @param _svtVesting SVT vesting contract.
    /// @param _provider Provider wallet.
    /// @param _developer Developer wallet.
    /// @param _treasury Treasury wallet.
    constructor(
        IERC20Metadata _paymentToken,
        IVesting _svtVesting,
        address _provider,
        address _developer,
        address _treasury
    ) {
        if (
            address(_paymentToken) == address(0) ||
            address(_svtVesting) == address(0) ||
            _provider == address(0) ||
            _developer == address(0) ||
            _treasury == address(0)
        ) revert ZeroAddress();
        paymentToken = _paymentToken;
        svtVesting = _svtVesting;
        provider = _provider;
        developer = _developer;
        treasury = _treasury;
        uint256 tokenDecimals = paymentToken.decimals();
        _plans[0] = Plan(
            uint128(MONTH_IN_SECONDS),
            200,
            5000,
            uint128(100 * 10 ** tokenDecimals)
        );
        _plans[1] = Plan(
            uint128(3 * MONTH_IN_SECONDS),
            400,
            10000,
            uint128(250 * 10 ** tokenDecimals)
        );
        _plans[2] = Plan(
            uint128(6 * MONTH_IN_SECONDS),
            600,
            20000,
            uint128(500 * 10 ** tokenDecimals)
        );
        _plans[3] = Plan(
            uint128(YEAR_IN_SECONDS),
            1000,
            30000,
            uint128(1000 * 10 ** tokenDecimals)
        );

        _referralSystemActivationFeeShares[0] = 4000;
        _referralSystemActivationFeeShares[1] = 2000;
        _referralSystemActivationFeeShares[2] = 1500;
        _referralSystemActivationFeeShares[3] = 1000;
        _referralSystemActivationFeeShares[4] = 700;
        _referralSystemActivationFeeShares[5] = 500;
        _referralSystemActivationFeeShares[6] = 300;

        _referralSystemRewardFeeShares[0] = 4667;
        _referralSystemRewardFeeShares[1] = 2000;
        _referralSystemRewardFeeShares[2] = 1333;
        _referralSystemRewardFeeShares[3] = 667;
        _referralSystemRewardFeeShares[4] = 667;
        _referralSystemRewardFeeShares[5] = 333;
        _referralSystemRewardFeeShares[6] = 333;

        _referralSystemSvtBonusFeeShares[0] = 4000;
        _referralSystemSvtBonusFeeShares[1] = 2000;
        _referralSystemSvtBonusFeeShares[2] = 1500;
        _referralSystemSvtBonusFeeShares[3] = 1000;
        _referralSystemSvtBonusFeeShares[4] = 700;
        _referralSystemSvtBonusFeeShares[5] = 500;
        _referralSystemSvtBonusFeeShares[6] = 300;
    }

    /// @notice Returns all configured plans.
    /// @return Array of plan structures.
    function getPlans() public view returns (Plan[PLAN_COUNT] memory) {
        return _plans;
    }

    /// @notice Returns a plan by index.
    /// @param planIndex Plan index.
    /// @return Plan structure at given index.
    function getPlan(uint256 planIndex) public view returns (Plan memory) {
        return _plans[planIndex];
    }

    /// @notice Returns whether a wallet has activated the given plan.
    /// @param wallet User wallet.
    /// @param planIndex Plan index.
    /// @return True if active, false otherwise.
    function isPlanActivated(address wallet, uint256 planIndex) public view returns (bool) {
        return _participants[wallet].isActive[planIndex];
    }

    /// @notice Returns investment details by user and index.
    /// @param wallet User wallet.
    /// @param investmentIndex Investment index in user array.
    /// @return Investment structure.
    function getInvestmentDetails(address wallet, uint256 investmentIndex) public view returns (Investment memory) {
        return _investments[wallet][investmentIndex];
    }

    /// @notice Returns number of investments for a wallet.
    /// @param wallet User wallet.
    /// @return Investment count.
    function getUserInvestmentCount(address wallet) public view returns (uint256) {
        return _investments[wallet].length;
    }

    /// @notice Returns accrued reward for an unclaimed investment.
    /// @param wallet User wallet.
    /// @param investmentIndex Investment index.
    /// @return Accrued reward amount, or zero if investment was already claimed.
    function getPendingRewardAmount(address wallet, uint256 investmentIndex) public view returns (uint256) {
        Investment storage investment = _investments[wallet][investmentIndex];
        if (investment.isLockedAmountWithdrawn) return 0;
        
        return _calculatePlanReward(investment.lockedAmount, investment.planIndex, investment.startTimestamp) - investment.claimedReward;
    }

    /// @notice Returns locked balance for a wallet at investment index.
    /// @param wallet User wallet.
    /// @param investmentIndex Investment index in storage.
    /// @return Locked amount or zero if claimed.
    function getLockedBalance(address wallet, uint256 investmentIndex) public view returns (uint256) {
        if (_investments[wallet][investmentIndex].isLockedAmountWithdrawn) return 0;
        return _investments[wallet][investmentIndex].lockedAmount;
    }

    /// @notice Returns total principal currently locked by wallet.
    /// @param wallet User wallet.
    /// @return Total locked principal.
    function getTotalLockedBalance(address wallet) public view returns (uint256) {
        return _participants[wallet].totalLockedAmount;
    }

    /// @notice Returns whether lock period has expired for a specific investment.
    /// @param wallet User wallet.
    /// @param investmentIndex Investment index.
    /// @return True if lock has expired.
    function isLockExpired(address wallet, uint256 investmentIndex) public view returns (bool) {
        Investment memory investment = _investments[wallet][investmentIndex];
        return block.timestamp >= investment.startTimestamp + _plans[investment.planIndex].lockDuration;
    }

    /// @notice Returns direct (level 0) referral count for wallet.
    /// @param wallet User wallet.
    /// @return Direct referral count.
    function getDirectReferralCount(address wallet) public view returns (uint256) {
        return _participants[wallet].referralCounts[0];
    }

    /// @notice Returns total referral count across all levels for wallet.
    /// @param wallet User wallet.
    /// @return Total referral count.
    function getTotalReferralCount(address wallet) public view returns (uint256) {
        uint256 totalReferralCount = 0;
        for (uint256 i = 0; i < REF_LEVEL_COUNT; i++) {
            totalReferralCount += _participants[wallet].referralCounts[i];
        }
        return totalReferralCount;
    }

    /// @notice Returns referral count by level for wallet.
    /// @param wallet User wallet.
    /// @param level Referral level.
    /// @return Referral count at level.
    function getReferralCountByLevel(address wallet, uint256 level) public view returns (uint256) {
        return _participants[wallet].referralCounts[level];
    }

    /// @notice Returns referral earnings by level for wallet.
    /// @param wallet User wallet.
    /// @param level Referral level.
    /// @return Referral earnings at level.
    function getReferralEarningsByLevel(address wallet, uint256 level) public view returns (uint256) {
        return _participants[wallet].referralEarnings[level];
    }

    /// @notice Returns total referral earnings across all levels for wallet.
    /// @param wallet User wallet.
    /// @return Total referral earnings.
    function getTotalReferralEarnings(address wallet) public view returns (uint256) {
        uint256 totalReferralEarnings = 0;
        for (uint256 i = 0; i < REF_LEVEL_COUNT; i++) {
            totalReferralEarnings += _participants[wallet].referralEarnings[i];
        }
        return totalReferralEarnings;
    }

    /// @notice Returns registered referrer for wallet.
    /// @param wallet User wallet.
    /// @return Referrer wallet or zero address.
    function getReferrer(address wallet) public view returns (address) {
        return _participants[wallet].referrer;
    }

    /// @notice Returns referral counts and earnings arrays for wallet.
    /// @param wallet User wallet.
    /// @return referralCounts Counts by each referral level.
    /// @return referralEarnings Earnings by each referral level.
    function getReferralSummary(address wallet)
        public
        view
        returns (
            uint256[REF_LEVEL_COUNT] memory referralCounts,
            uint256[REF_LEVEL_COUNT] memory referralEarnings
        ) {
            referralCounts = _participants[wallet].referralCounts;
            referralEarnings = _participants[wallet].referralEarnings;
    }

    /// @notice Returns activation referral share table.
    /// @return Shares by level in basis points.
    function getReferralSystemActivationFeeShares() public view returns (uint256[REF_LEVEL_COUNT] memory) {
        return _referralSystemActivationFeeShares;
    }

    /// @notice Returns withdrawal reward referral share table.
    /// @return Shares by level in basis points.
    function getReferralSystemRewardFeeShares() public view returns (uint256[REF_LEVEL_COUNT] memory) {
        return _referralSystemRewardFeeShares;
    }

    /// @notice Returns SVT bonus referral share table.
    /// @return Shares by level in basis points.
    function getReferralSystemSvtBonusFeeShares() public view returns (uint256[REF_LEVEL_COUNT] memory) {
        return _referralSystemSvtBonusFeeShares;
    }

    /// @notice Returns unclaimed referral system reward balance for wallet.
    /// @param wallet User wallet.
    /// @return Unclaimed referral system reward balance.
    function getUnclaimedReferralSystemReward(address wallet) public view returns (uint256) {
        return _participants[wallet].referralSystemReward;
    }

    /// @notice Activates a plan for caller and charges activation fee.
    /// @param planIndex Plan index to activate.
    /// @param referrer Optional referrer wallet for first activation.
    function activatePlan(uint256 planIndex, address referrer) public nonReentrant {
        if (planIndex >= PLAN_COUNT) revert InvalidPlanIndex();
        if (_participants[msg.sender].isActive[planIndex]) revert PlanAlreadyActivated();
        uint256 activationFee = _plans[planIndex].activationFee;

        bool isFirstPlanActivation = true;
        for (uint256 i = 0; i < PLAN_COUNT; i++) {
            if (_participants[msg.sender].isActive[i]) {
                isFirstPlanActivation = false;
                break;
            }
        }
        if (isFirstPlanActivation) {
            _registerReferrer(msg.sender, referrer);
        }

        paymentToken.safeTransferFrom(msg.sender, address(this), activationFee);

        _participants[msg.sender].isActive[planIndex] = true;
        uint256 referralSystemReward = activationFee / 2;

        _distributeReferralFee(referralSystemReward, _referralSystemActivationFeeShares);
        paymentToken.safeTransfer(provider, activationFee - referralSystemReward);

        emit PlanActivated(msg.sender, planIndex);
    }

    /// @notice Invests funds into an activated plan.
    /// @dev Credits `contractTokenAmount` by the requested `amount` (half retained on contract);
    ///      requires `paymentToken` to deliver exactly `amount` on transfer (see `paymentToken`).
    /// @param amount Investment amount.
    /// @param planIndex Activated plan index.
    function invest(uint256 amount, uint256 planIndex) public nonReentrant {
        if (planIndex >= PLAN_COUNT) revert InvalidPlanIndex();
        if (!_participants[msg.sender].isActive[planIndex]) revert PlanNotActivated();
        if (amount == 0) revert InvalidAmount();

        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        _investments[msg.sender].push(Investment(amount, block.timestamp, planIndex, 0, false));
        _participants[msg.sender].totalLockedAmount += amount;
        bool isFirstInvestment = !_participants[msg.sender].isDeposited;
        if (isFirstInvestment) {
            _participants[msg.sender].isDeposited = true;
        }
        _distributeSvtBonus(msg.sender, planIndex, amount, isFirstInvestment);
        uint256 providerAmount = amount / 2;

        contractTokenAmount += amount - providerAmount;
        paymentToken.safeTransfer(provider, providerAmount);

        emit InvestmentMade(msg.sender, amount, planIndex);
    }

    /// @notice Withdraws matured investment.
    /// @param investmentIndex Investment index in caller portfolio.
    function withdraw(uint256 investmentIndex) public nonReentrant {
        if (investmentIndex >= _investments[msg.sender].length) revert InvalidInvestmentIndex();
        Investment storage investment = _investments[msg.sender][investmentIndex];
        if (block.timestamp < investment.startTimestamp + _plans[investment.planIndex].lockDuration) revert InvestmentLocked();
        if (investment.isLockedAmountWithdrawn) revert InvestmentAlreadyWithdrawn();

        uint256 planReward = _calculatePlanReward(investment.lockedAmount, investment.planIndex, investment.startTimestamp);
        uint256 reward = planReward - investment.claimedReward;
        uint256 referralReward = _participants[msg.sender].referralSystemReward;
        investment.claimedReward += reward;
        _participants[msg.sender].totalLockedAmount -= investment.lockedAmount;
        _participants[msg.sender].referralSystemReward = 0;
        investment.isLockedAmountWithdrawn = true;

        _distributeWithdraw(msg.sender, investment.lockedAmount, reward, referralReward);
        
        emit InvestmentWithdrawn(msg.sender, investmentIndex, investment.lockedAmount, reward);
    }

    /// @notice Claims currently accrued plan reward and caller's referral reward, without withdrawing principal.
    /// @dev Keeps investment active by updating only claimed reward state.
    /// @param investmentIndex Investment index in caller portfolio.
    function claimRewards(uint256 investmentIndex) public nonReentrant {
        if (investmentIndex >= _investments[msg.sender].length) revert InvalidInvestmentIndex();
        Investment storage investment = _investments[msg.sender][investmentIndex];
        if (investment.isLockedAmountWithdrawn) revert InvestmentAlreadyWithdrawn();

        uint256 planReward = _calculatePlanReward(
            investment.lockedAmount,
            investment.planIndex,
            investment.startTimestamp
        );
        uint256 reward = planReward - investment.claimedReward;
        uint256 referralReward = _participants[msg.sender].referralSystemReward;

        if (reward + referralReward == 0) revert NoRewardsToClaim();
        if (contractTokenAmount < reward) revert InsufficientFunds();

        investment.claimedReward += reward;
        _participants[msg.sender].referralSystemReward = 0;
        
        _distributeWithdraw(msg.sender, 0, reward, referralReward);
    }

    /// @notice Withdraws accumulated referral reward for caller.
    function withdrawReferralReward() public nonReentrant {
        uint256 referralReward = _participants[msg.sender].referralSystemReward;
        if (referralReward == 0) revert NoReferralReward();
        _participants[msg.sender].referralSystemReward = 0;
        paymentToken.safeTransfer(msg.sender, referralReward);
        emit ReferralRewardWithdrawn(msg.sender, referralReward);
    }

    /// @notice Deposits extra liquidity.
    /// @dev Credits `contractTokenAmount` by the requested `amount`; requires `paymentToken` to
    ///      deliver exactly `amount` on transfer (see `paymentToken`).
    /// @param amount Amount to deposit.
    function deposit(uint256 amount) public nonReentrant {
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        contractTokenAmount += amount;
        
        emit Deposited(msg.sender, amount);
    }

    /// @dev Distributes withdrawal proceeds and reward fees.
    /// @param wallet Receiver wallet.
    /// @param amount Principal amount.
    /// @param reward Gross reward amount.
    function _distributeWithdraw(address wallet, uint256 amount, uint256 reward, uint256 referralReward) private {
        if (contractTokenAmount < amount + reward) revert InsufficientFunds();
        uint256 rewardFee = reward * 2000 / PCT_BASE;
        uint256 developerAmount = rewardFee * 2500 / PCT_BASE;
        uint256 referralSystemReward = rewardFee - developerAmount;
        contractTokenAmount -= amount + reward;
        reward -= rewardFee;
        _distributeReferralFee(referralSystemReward, _referralSystemRewardFeeShares);
        paymentToken.safeTransfer(developer, developerAmount);
        paymentToken.safeTransfer(wallet, amount + reward + referralReward);

        emit Withdraw(wallet, amount, reward, referralReward, rewardFee);
    }

    /// @dev Calculates reward for a plan using full elapsed time since investment start.
    /// @param amount Principal amount.
    /// @param planIndex Plan index.
    /// @param startTimestamp Investment start timestamp.
    /// @return reward Reward amount.
    function _calculatePlanReward(uint256 amount, uint256 planIndex, uint256 startTimestamp) private view returns (uint256 reward) {
        uint256 monthlyReturnBps = _plans[planIndex].monthlyReturnBps;
        uint256 currentTimestamp = block.timestamp;
        uint256 secondsSinceStart = currentTimestamp - startTimestamp;
        uint256 lockDuration = _plans[planIndex].lockDuration;
        if (secondsSinceStart > lockDuration) secondsSinceStart = lockDuration;
        reward = amount * monthlyReturnBps * secondsSinceStart / (PCT_BASE * MONTH_IN_SECONDS);
    }

    /// @dev Registers referrer for wallet on first activation.
    /// @param wallet Referred wallet.
    /// @param referrer Referrer wallet.
    function _registerReferrer(address wallet, address referrer) private {
        if (referrer == wallet) revert InvalidReferrer();
        _participants[wallet].referrer = referrer;
        _checkRefererCirculation(referrer);
        if (referrer != address(0)) {
            emit ReferrerRegistered(wallet, referrer);

            for (uint256 i = 0; i < REF_LEVEL_COUNT; i++) {
                if (referrer == address(0)) break;
                _participants[referrer].referralCounts[i]++;
                referrer = _participants[referrer].referrer;
            }
        }
    }

    /// @dev Checks referral graph for simple circulation pattern.
    /// @param referer Initial referrer to validate.
    function _checkRefererCirculation(address referer) internal view {
        address directReferer = referer;
        if (referer != address(0)) {
            for (uint i = 0; i < REF_LEVEL_COUNT; i++) {
                referer = _participants[referer].referrer;
                if (referer == address(0)) break;
                if (referer == directReferer) revert ReferralCirculationDetected();
            }
        }
    }

    /// @dev Distributes referral pool by level or sends remainder to treasury.
    /// @param referralSystemReward Total referral pool amount.
    /// @param refRewardFeeShares Share table used for distribution.
    function _distributeReferralFee(uint256 referralSystemReward, uint256[REF_LEVEL_COUNT] storage refRewardFeeShares) private {
        uint256 treasuryAmount = 0;
        uint256 totalDistrubuted = 0;
        address referrer = _participants[msg.sender].referrer;
        for (uint256 i = 0; i < REF_LEVEL_COUNT; i++) {
            uint256 distributedAmount = referralSystemReward * refRewardFeeShares[i] / PCT_BASE;
            if (i == REF_LEVEL_COUNT - 1) {
                distributedAmount = referralSystemReward - totalDistrubuted;
            }
            if (referrer == address(0)) {
                treasuryAmount += distributedAmount;
            } else {
                _participants[referrer].referralSystemReward += distributedAmount;
                _participants[referrer].referralEarnings[i] += distributedAmount;
                emit ReferralFeeDistributed(referrer, msg.sender, i, distributedAmount);
            }
            totalDistrubuted += distributedAmount;
            referrer = _participants[referrer].referrer;
        }
        if (treasuryAmount > 0) {
            paymentToken.safeTransfer(treasury, treasuryAmount);
        }
    }

    function _distributeSvtBonus(address wallet, uint256 planIndex, uint256 investmentAmount, bool isFirstInvestment) private {
        uint256 svtBonusMultiplier = _plans[planIndex].svtBonusMultiplier;
        IERC20Metadata svt = IERC20Metadata(svtVesting.svt());
        uint256 svtDecimals = svt.decimals();
        uint256 paymentTokenDecimals = paymentToken.decimals();
        uint256 svtBonus = investmentAmount * svtBonusMultiplier / PCT_BASE;
        svtBonus = svtBonus * 10 ** (svtDecimals - paymentTokenDecimals);
        if (svtBonus > 0) {
            svtVesting.createVestingSchedule(wallet, svtBonus);
        }

        if (isFirstInvestment) {
            uint256 referralSystemReward = svtBonus * 5000 / PCT_BASE;
            address referrer = _participants[msg.sender].referrer;
            for (uint256 i = 0; i < REF_LEVEL_COUNT; i++) {
                if (referrer == address(0)) break;
                uint256 distributedAmount = referralSystemReward * _referralSystemSvtBonusFeeShares[i] / PCT_BASE;
                if (distributedAmount > 0) { 
                svtVesting.createVestingSchedule(referrer, distributedAmount);
                }
                referrer = _participants[referrer].referrer;
            }
        }
    }
}
