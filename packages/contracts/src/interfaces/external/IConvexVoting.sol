// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICvxLocker
/// @notice Interface for Convex's CvxLockerV2 (vlCVX)
interface ICvxLocker {
    struct LockedBalance {
        uint112 amount;
        uint112 boosted;
        uint32 unlockTime;
    }

    struct EarnedData {
        address token;
        uint256 amount;
    }

    /// @notice Lock CVX tokens
    /// @param _account Account to lock for
    /// @param _amount Amount of CVX to lock
    /// @param _spendRatio Boost spending ratio (0 = no boost)
    function lock(address _account, uint256 _amount, uint256 _spendRatio) external;

    /// @notice Process expired locks and optionally relock
    /// @param relock If true, relock the expired CVX
    function processExpiredLocks(bool relock) external;

    /// @notice Get all earned rewards
    /// @param _account Account to check
    /// @return claimable Array of earned reward data
    function claimableRewards(address _account) external view returns (EarnedData[] memory claimable);

    /// @notice Claim all rewards
    /// @param _account Account to claim for
    /// @param _stake Whether to stake claimed CVX
    function getReward(address _account, bool _stake) external;

    /// @notice Get locked balance for account
    /// @param _account Account to check
    /// @return Locked balance amount
    function lockedBalanceOf(address _account) external view returns (uint256);

    /// @notice Get total locked balance including boost
    /// @param _account Account to check
    /// @return Total balance
    function balanceOf(address _account) external view returns (uint256);

    /// @notice Get locked balances array
    /// @param _account Account to check
    /// @return lockData Array of locked balance structs
    function lockedBalances(address _account) external view returns (
        uint256 total,
        uint256 unlockable,
        uint256 locked,
        LockedBalance[] memory lockData
    );

    /// @notice Get list of reward tokens
    /// @return Array of reward token addresses
    function rewardTokens() external view returns (address[] memory);

    /// @notice Current epoch count
    /// @return Current epoch
    function epochCount() external view returns (uint256);

    /// @notice Withdraw expired locks without relocking
    function withdrawExpiredLocksTo(address _withdrawTo) external;

    /// @notice Kick expired locks for a user (callable by anyone after grace period)
    /// @param _account Account to kick
    function kickExpiredLocks(address _account) external;
}

/// @title ICvxVoteProxy
/// @notice Interface for Convex's voting proxy/delegation
interface ICvxVoteProxy {
    /// @notice Vote on a Curve gauge (if Convex supports on-chain voting)
    /// @param _gauge Gauge address
    /// @param _weight Weight to vote with
    function voteGaugeWeight(address _gauge, uint256 _weight) external;

    /// @notice Vote on multiple gauges
    /// @param _gauges Array of gauge addresses
    /// @param _weights Array of weights
    function voteMultipleGauges(address[] calldata _gauges, uint256[] calldata _weights) external;
}
