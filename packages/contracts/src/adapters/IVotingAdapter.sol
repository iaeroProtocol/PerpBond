// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Optional voting surface for strategy adapters (e.g., veAERO, vePENDLE, vlCVX).
/// @dev    The caller is typically a dedicated voter router/keeper.
interface IVotingAdapter {
    /// @param gauges  Target gauge/pool addresses to vote on.
    /// @param weights Adapter-specific weights (bps or raw units, as documented by the adapter).
    function vote(address[] calldata gauges, uint256[] calldata weights) external;
}
