// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Optional interface for adapters that lock tokens for a duration.
/// @dev Return 0 when the position is not locked.
interface ILockingAdapter {
    /// @return timestamp Unix timestamp when the main position unlocks (0 if not locked).
    function lockedUntil() external view returns (uint256 timestamp);
}
