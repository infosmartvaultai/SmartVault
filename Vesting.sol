// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title Vesting
 * @dev Linear token vesting contract with a fixed 1 year duration per schedule
 */
contract Vesting is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when zero address is provided
    error ZeroAddress();

    /// @notice Error thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Error thrown when the array lengths are not equal
    error InvalidArrayLength();

    /// @notice Error thrown when trying to set `botLocking` more than once
    error BotLockingAlreadySet();

    /// @notice Error thrown when caller is not the configured `botLocking` contract
    error OnlyBotLocking();

    /// @notice Error thrown when there is nothing to release
    error NothingToRelease();

    /// @notice Error thrown when there are insufficient tokens to recover
    error InsufficientTokens();

    /// @notice Error thrown when the contract is not fully distributed
    error NotFullyDistributed();

    /**
     * @dev Struct containing vesting information for each beneficiary
     * @param start The timestamp when vesting starts
     * @param released The amount of tokens already released
     * @param vestedAmount The total amount of tokens in the vesting schedule
     */
    struct VestingInfo {
        uint256 start;
        uint256 released;
        uint256 vestedAmount;
    }

    /// @notice Mapping of beneficiary addresses to their vesting information
    mapping(address => VestingInfo[]) public vestingSchedules;

    /// @notice Maximum total amount of tokens distributable across all vesting schedules
    uint256 public constant MAX_AIRDROP_POOL = 10_000_000 * 10 ** 18;
    
    /// @notice The SVT token that gets released to beneficiaries
    IERC20 public immutable svt;

    /// @notice The only address allowed to create vesting schedules
    address public botLocking;

    /// @notice Sum of all tokens allocated via created schedules
    uint256 public totalDistributedTokens;

    /// @notice Sum of all tokens released from vesting schedules
    uint256 public totalReleasedTokens;

    /// @notice Vesting duration constant: 1 year (365 days, expressed in seconds)
    uint256 private constant _duration = 365 days; // 1 year

    /// @notice Emitted when a new vesting schedule is created
    /// @param beneficiary The address of the beneficiary
    /// @param vestingIndex The index of the vesting schedule
    /// @param amount The amount of tokens being vested
    /// @param start The timestamp when vesting starts
    event VestingScheduleCreated(address beneficiary, uint256 vestingIndex, uint256 amount, uint256 start);
    
    /// @notice Emitted when tokens are released to a beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @param amount The amount of tokens released
    event VestingReleased(address beneficiary, uint256 amount);

    /// @notice Emitted when surplus tokens are recovered
    /// @param to The address to transfer the surplus tokens to
    /// @param amount The amount of tokens recovered
    event SurplusRecovered(address to, uint256 amount);

    /// @notice Emitted when the airdrop pool is exhausted
    /// @param beneficiary The address of the beneficiary
    /// @param requested The amount of tokens requested
    event AirdropPoolExhausted(address indexed beneficiary, uint256 requested);

    /// @notice Emitted when the airdrop pool is partially allocated
    /// @param beneficiary The address of the beneficiary
    /// @param requested The amount of tokens requested
    /// @param allocated The amount of tokens allocated
    event AirdropPoolPartiallyAllocated(address indexed beneficiary, uint256 requested, uint256 allocated);

    /**
     * @dev Initializes the Vesting contract
     * @param _svt The ERC20 token that will be vested and released to beneficiaries
     * @notice The token address must be non-zero
     */
    constructor(IERC20 _svt) Ownable(msg.sender) {
        if (address(_svt) == address(0)) revert ZeroAddress();
        svt = _svt;
    }

    /// @notice Recover SVT held above the outstanding (allocated-but-unreleased) obligation.
    /// @dev Can only be called by the owner when the contract is fully distributed.
    /// @param to The address to transfer the surplus tokens to
    /// @param amount The amount of tokens to transfer
    /// @notice Reverts if the contract is not fully distributed or if there are insufficient tokens to recover.
    function recoverSurplus(address to, uint256 amount) external onlyOwner {
        if (totalDistributedTokens != MAX_AIRDROP_POOL) revert NotFullyDistributed();
        uint256 outstanding = totalDistributedTokens - totalReleasedTokens;
        uint256 surplus = svt.balanceOf(address(this)) < outstanding ? 0 : svt.balanceOf(address(this)) - outstanding;
        if (amount > surplus) revert InsufficientTokens();
        svt.safeTransfer(to, amount);
        emit SurplusRecovered(to, amount);
    }


    /**
     * @notice Returns the number of vesting schedules for a beneficiary
     * @param beneficiary The address of the beneficiary
     * @return The number of vesting schedules for the beneficiary
     */
    function vestingSchedulesLength(address beneficiary) external view returns (uint256) {
        return vestingSchedules[beneficiary].length;
    }

    /**
     * @notice Sets the `botLocking` contract address once
     * @dev Can only be called by the owner; cannot be updated after first set
     * @param _botLocking The address that will be allowed to call `createVestingSchedule`
     */
    function setBotLocking(address _botLocking) external onlyOwner {
        if (_botLocking == address(0)) revert ZeroAddress();
        if (botLocking != address(0)) revert BotLockingAlreadySet();
        botLocking = _botLocking;
    }

    /**
     * @notice Creates a new vesting schedule for a beneficiary
     * @dev Only callable by `botLocking`; updates vesting storage and accounting
     * @param beneficiary The beneficiary that will receive vested tokens
     * @param amount The amount of tokens to allocate to the beneficiary
     */
    function createVestingSchedule(address beneficiary, uint256 amount) external {
        if (msg.sender != botLocking) revert OnlyBotLocking();
        _createVestingSchedule(beneficiary, amount);
    }

    /**
     * @notice Returns the fixed vesting duration used by all schedules
     * @dev Getter for the vesting duration
     * @return The vesting duration in seconds (365 days)
     */
    function duration() public pure returns (uint256) {
        return _duration;
    }

    /**
     * @notice Returns the start timestamp of a beneficiary's vesting schedule
     * @param beneficiary The address of the beneficiary
     * @param vestingIndex The index of the vesting schedule
     * @return The timestamp when vesting starts for the beneficiary
     */
    function start(address beneficiary, uint256 vestingIndex) public view virtual returns (uint256) {
        return vestingSchedules[beneficiary][vestingIndex].start;
    }

    /**
     * @notice Returns the end timestamp of a beneficiary's vesting schedule
     * @dev Derived as `start + duration()`
     * @param beneficiary The address of the beneficiary
     * @param vestingIndex The index of the vesting schedule
     * @return The timestamp when vesting ends for the beneficiary
     */
    function end(address beneficiary, uint256 vestingIndex) public view virtual returns (uint256) {
        return start(beneficiary, vestingIndex) + duration();
    }

    /**
     * @notice Returns amount of tokens already released for a schedule
     * @param beneficiary The address of the beneficiary
     * @param vestingIndex The index of the vesting schedule
     * @return The amount of tokens already released
     */
    function released(address beneficiary, uint256 vestingIndex) public view virtual returns (uint256) {
        return vestingSchedules[beneficiary][vestingIndex].released;
    }

    /**
     * @notice Returns how many tokens can be claimed right now
     * @dev Computed as `vestedAmount(...) - released(...)`
     * @param beneficiary The address of the beneficiary
     * @param vestingIndex The index of the vesting schedule
     * @return The amount of tokens that can be released right now
     */
    function releasable(address beneficiary, uint256 vestingIndex) public view virtual returns (uint256) {
        return vestedAmount(beneficiary, vestingIndex, uint64(block.timestamp)) - released(beneficiary, vestingIndex);
    }

    /**
     * @notice Releases currently vested tokens for caller's selected schedule
     * @dev Reverts if `vestingIndex` is invalid due to array access; can emit zero-amount release
     * @param vestingIndex The index of the vesting schedule
     * @notice Emits a {VestingReleased} event
     */
    function release(uint256 vestingIndex) public virtual {
        address beneficiary = msg.sender;
        uint256 amount = releasable(beneficiary, vestingIndex);
        if (amount == 0) revert NothingToRelease();
        vestingSchedules[beneficiary][vestingIndex].released += amount;
        totalReleasedTokens += amount;
        emit VestingReleased(beneficiary, amount);
        svt.safeTransfer(beneficiary, amount);
    }

    /**
     * @notice Calculates vested amount for a schedule at a given timestamp
     * @dev Uses `_vestingSchedule` linear formula over a 365-day duration
     * @param beneficiary The address of the beneficiary
     * @param vestingIndex The index of the vesting schedule
     * @param timestamp The timestamp to calculate vested amount for
     * @return The amount of tokens that have vested by the given timestamp
     */
    function vestedAmount(address beneficiary, uint256 vestingIndex, uint64 timestamp) public view virtual returns (uint256) {
        return _vestingSchedule(
            vestingSchedules[beneficiary][vestingIndex].vestedAmount,
            timestamp,
            start(beneficiary, vestingIndex),
            end(beneficiary, vestingIndex)
        );
    }

    /**
     * @notice Internal schedule creation helper with allocation cap checks
     * @dev Records schedule start at `block.timestamp` and updates `totalDistributedTokens`
     * @param beneficiary The address receiving the vesting allocation
     * @param amount The amount of tokens to allocate
     */
    function _createVestingSchedule(address beneficiary, uint256 amount) internal {
        uint256 vestingIndex = vestingSchedules[beneficiary].length;
        if (amount == 0) revert ZeroAmount();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (totalDistributedTokens == MAX_AIRDROP_POOL) {
            emit AirdropPoolExhausted(beneficiary, amount);
            return;
        }

        uint256 amountToAllocate = amount;
        if (totalDistributedTokens + amount > MAX_AIRDROP_POOL) {
            amountToAllocate = MAX_AIRDROP_POOL - totalDistributedTokens;
            emit AirdropPoolPartiallyAllocated(beneficiary, amount, amountToAllocate);
        }
        totalDistributedTokens += amountToAllocate;
        vestingSchedules[beneficiary].push(VestingInfo({
            start: block.timestamp,
            released: 0,
            vestedAmount: amountToAllocate
        }));

        emit VestingScheduleCreated(beneficiary, vestingIndex, amountToAllocate, block.timestamp);
    }

    /**
     * @notice Returns vested amount for a linear vesting interval
     * @param totalAllocation The total amount of tokens allocated for vesting
     * @param timestamp The timestamp to calculate vested amount for
     * @param startTimestamp The timestamp when vesting starts
     * @param endTimestamp The timestamp when vesting ends
     * @return The amount of tokens that have vested by the given timestamp
     * @notice Tokens vest linearly between the start and end timestamps
     * @notice Integer division results in minimal precision loss that is considered acceptable
     */
    function _vestingSchedule(
        uint256 totalAllocation,
        uint64 timestamp,
        uint256 startTimestamp,
        uint256 endTimestamp
    ) internal view virtual returns (uint256) {
        if (timestamp < startTimestamp) {
            return 0;
        } else if (timestamp >= endTimestamp) {
            return totalAllocation;
        } else {            
            // Release tokens proportionally to complete seconds passed
            return (totalAllocation * (timestamp - startTimestamp)) / duration();
        }
    }
}
