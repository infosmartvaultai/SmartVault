// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Staking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The error thrown when the address is zero.
    error ZeroAddress();
    /// @notice The error thrown when the amount is invalid.
    error InvalidAmount();
    /// @notice The error thrown when the balance is insufficient.
    error InsufficientBalance();
    /// @notice The error thrown when the start time is invalid.
    error InvalidStartTime();
    /// @notice The error thrown when the staking has already been initialized.
    error StakingAlreadyInitialized();
    /// @notice The error thrown when the staking has not been initialized.
    error StakingNotInitialized();
    /// @notice The error thrown when the staking has ended.
    error StakingEnded();
    /// @notice The error thrown when the staking has not ended.
    error StakingNotEnded();
    /// @notice The error thrown when there is no remainder to sweep.
    error NoRemainderToSweep();

    /// @notice The SVT token contract. Staking and reward token.
    IERC20 public immutable svtToken;
    /// @notice The reward pool. 5,000,000 SVT tokens.
    uint256 public constant rewardPool = 5_000_000 * 1e18; // 5,000,000 SVT tokens
    /// @notice The duration of rewards to be paid out (in seconds). 5 years.
    uint256 public constant duration = 157_680_000; // 5 years
    /// @notice The reward to be paid out per second.
    uint256 public constant rewardRate = rewardPool / duration;
    /// @notice The timestamp of when the rewards start.
    uint256 public startTime;
    /// @notice The timestamp of when the rewards end.
    uint256 public endTime;
    /// @notice The minimum of last updated time and reward finish time.
    uint256 public updatedAt;
    /// @notice The sum of (reward rate * dt * 1e18 / total supply).
    uint256 public rewardPerTokenStored;
    /// @notice The account address => rewardPerTokenStored.
    mapping(address => uint256) public userRewardPerTokenPaid;
    /// @notice The account address => rewards to be claimed.
    mapping(address => uint256) public rewards;

    /// @notice The total staked.
    uint256 public totalStaked;
    /// @notice The total rewards emitted.
    uint256 public totalRewardsEmitted;
    /// @notice The total rewards claimed.
    uint256 public totalRewardsClaimed;
    /// @notice The account address => staked amount.
    mapping(address => uint256) public balanceOf;

    /// @notice The event emitted when the staking is initialized.
    event Initialized(uint256 startTime);
    /// @notice The event emitted when the SVT tokens are staked.
    event Staked(address indexed account, uint256 amount);
    /// @notice The event emitted when the SVT tokens are unstaked.
    event Unstaked(address indexed account, uint256 amount);
    /// @notice The event emitted when the rewards are claimed.
    event RewardPaid(address indexed account, uint256 amount);
    /// @notice The event emitted when the remainder is swept.
    event RemainderSwept(address indexed to, uint256 amount);

    /// @notice Updates the reward per token stored and the rewards to be claimed.
    /// @param account The account to update the reward for.
    modifier updateReward(address account) {
        if (startTime == 0) revert StakingNotInitialized();
        uint256 oldRewardPerTokenStored = rewardPerTokenStored;
        rewardPerTokenStored = rewardPerToken();
        if (rewardPerTokenStored > oldRewardPerTokenStored) {
            totalRewardsEmitted += rewardRate * (lastTimeRewardApplicable() - updatedAt);
        }
        updatedAt = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    constructor(address _svtToken) Ownable(msg.sender) {
        if (_svtToken == address(0)) revert ZeroAddress();
        svtToken = IERC20(_svtToken);
    }

    function initialize(uint256 _startTime) external onlyOwner nonReentrant {
        if (_startTime < block.timestamp) revert InvalidStartTime();
        if (startTime != 0) revert StakingAlreadyInitialized();
        startTime = _startTime;
        updatedAt = _startTime;
        endTime = _startTime + duration;
        svtToken.safeTransferFrom(msg.sender, address(this), rewardPool);
        emit Initialized(_startTime);
    }

    /// @notice The last time the reward was applicable.
    function lastTimeRewardApplicable() public view returns (uint256) {
        if (block.timestamp > endTime) {
            return endTime;
        } if (block.timestamp < startTime) {
            return startTime;
        } else {
            return block.timestamp;
        }
    }

    /// @notice The reward per token stored.
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0 || startTime == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored
            + (rewardRate * (lastTimeRewardApplicable() - updatedAt) * 1e18)
                / totalStaked;
    }

    /// @notice Stakes the SVT tokens.
    /// @param amount The amount of SVT tokens to stake.
    function stake(uint256 amount) external updateReward(msg.sender) nonReentrant {
        if (block.timestamp >= endTime) revert StakingEnded();
        if (amount == 0) revert InvalidAmount();
        svtToken.safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    /// @notice Unstakes the SVT tokens.
    /// @param amount The amount of SVT tokens to unstake.
    function unstake(uint256 amount) external updateReward(msg.sender) nonReentrant {
        _unstake(msg.sender, amount);
    }

    /// @notice The rewards earned by the account.
    /// @param account The account to get the rewards for.
    function earned(address account) public view returns (uint256) {
        return (
            (
                balanceOf[account]
                    * (rewardPerToken() - userRewardPerTokenPaid[account])
            ) / 1e18
        ) + rewards[account];
    }

    /// @notice The remaining rewards.
    function remainingRewards() public view returns (uint256) {
        if (startTime == 0) return rewardRate * duration;
        return rewardRate * (endTime - lastTimeRewardApplicable());
    }

    /// @notice Claims the rewards.
    /// @dev The rewards are claimed by the account.
    function claim() external updateReward(msg.sender) nonReentrant {
        _claim(msg.sender);
    }

    /// @notice Exits the staking and claims the rewards.
    function exit() external updateReward(msg.sender) nonReentrant {
        uint256 balance = balanceOf[msg.sender];
        if (balance > 0) {
            _unstake(msg.sender, balance);
        }
        _claim(msg.sender);
    }

    /// @notice Sweeps the remainder of the SVT tokens.
    /// @dev Can only be called by owner after the staking has ended.
    /// @param to The address to sweep the remainder to.
    function sweepRemainder(address to) external updateReward(address(0)) onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (block.timestamp < endTime) revert StakingNotEnded();
        uint256 remainder = svtToken.balanceOf(address(this)) - totalStaked - (totalRewardsEmitted - totalRewardsClaimed);
        if (remainder == 0) revert NoRemainderToSweep();
        svtToken.safeTransfer(to, remainder);
        emit RemainderSwept(to, remainder);
    }

    function _unstake(address account, uint256 amount) private {
        if (amount == 0) revert InvalidAmount();
        if (amount > balanceOf[account]) revert InsufficientBalance();
        balanceOf[account] -= amount;
        totalStaked -= amount;
        svtToken.safeTransfer(account, amount);
        emit Unstaked(account, amount);
    }

    function _claim(address account) private {
        uint256 reward = rewards[account];
        rewards[account] = 0;
        if (reward > 0) {
            totalRewardsClaimed += reward;
            svtToken.safeTransfer(account, reward);
            emit RewardPaid(account, reward);
        }
    }
}
