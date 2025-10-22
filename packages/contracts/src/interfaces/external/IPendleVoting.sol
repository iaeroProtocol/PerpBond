// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPendleVotingEscrow
/// @notice Interface for Pendle's Voting Escrow (vePENDLE)
interface IPendleVotingEscrow {
    struct LockedBalance {
        uint128 amount;
        uint128 expiry;
    }

    /// @notice Create a new lock
    /// @param _value Amount of PENDLE to lock
    /// @param _unlockTime Unix timestamp when lock expires (must be rounded to weeks)
    function create_lock(uint256 _value, uint128 _unlockTime) external;

    /// @notice Increase the amount locked
    /// @param _value Additional amount to lock
    function increase_amount(uint256 _value) external;

    /// @notice Extend the unlock time
    /// @param _unlockTime New unlock timestamp (must be > current)
    function increase_unlock_time(uint128 _unlockTime) external;

    /// @notice Withdraw from an expired lock
    function withdraw() external;

    /// @notice Get locked balance for an address
    /// @param addr User address
    /// @return Locked balance struct
    function locked(address addr) external view returns (LockedBalance memory);

    /// @notice Get voting power balance
    /// @param addr User address
    /// @return Voting power balance
    function balanceOf(address addr) external view returns (uint256);

    /// @notice Get total voting power supply
    /// @return Total supply
    function totalSupply() external view returns (uint256);
}

/// @title IPendleGaugeController
/// @notice Interface for Pendle's Gauge Controller for voting
interface IPendleGaugeController {
    /// @notice Vote for gauge weights
    /// @param gauge_addr Gauge address
    /// @param user_weight Weight allocated (in basis points, max 10000)
    function vote_for_gauge_weights(address gauge_addr, uint256 user_weight) external;

    /// @notice Get user's vote weight for a gauge
    /// @param user User address
    /// @param gauge Gauge address
    /// @return Weight allocated
    function vote_user_power(address user, address gauge) external view returns (uint256);

    /// @notice Get user's total used voting power
    /// @param user User address
    /// @return Total power used
    function vote_user_power_used(address user) external view returns (uint256);

    /// @notice Get last time user voted
    /// @param user User address
    /// @return Last vote timestamp
    function last_user_vote(address user, address gauge) external view returns (uint256);
}

/// @title IPendleFeeDistributor
/// @notice Interface for Pendle's Fee Distributor for claiming rewards
interface IPendleFeeDistributor {
    /// @notice Claim vePENDLE rewards
    /// @param user User address
    /// @return Amount claimed
    function claim(address user) external returns (uint256);

    /// @notice Get claimable amount for user
    /// @param user User address
    /// @return Claimable amount
    function claimable(address user) external view returns (uint256);
}
