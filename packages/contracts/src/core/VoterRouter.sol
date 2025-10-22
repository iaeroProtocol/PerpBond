// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AccessRoles.sol";
import "./ErrorsEvents.sol";
import "./AdapterRegistry.sol";
import "./IVotingAdapter.sol";

/// @notice Routes governance votes to strategy adapters that implement IVotingAdapter.
contract VoterRouter is AccessRoles, ErrorsEvents {
    AdapterRegistry public registry;

    event RegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event AdapterVoted(address indexed adapter, uint256 items);
    event VotesExecuted(uint256 intentsProcessed);

    struct VoteIntent {
        address adapter;
        address[] gauges;
        uint256[] weights;
    }

    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address registry_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (registry_ == address(0)) revert IErrors.ZeroAddress();
        registry = AdapterRegistry(registry_);
    }

    /// @notice Governor may update the registry.
    function setRegistry(address newRegistry) external onlyGovernor {
        if (newRegistry == address(0)) revert IErrors.ZeroAddress();
        address old = address(registry);
        registry = AdapterRegistry(newRegistry);
        emit RegistrySet(old, newRegistry);
    }

    /// @notice Execute a batch of voting intents across adapters.
    /// @dev    Reverts if any adapter is inactive or arrays mismatch.
    function executeVotes(VoteIntent[] calldata intents) external onlyKeeper whenNotPaused {
        uint256 n = intents.length;
        for (uint256 i = 0; i < n; ++i) {
            VoteIntent calldata v = intents[i];

            // Validate adapter exists & is active
            AdapterRegistry.AdapterInfo memory info = registry.getAdapter(v.adapter);
            if (!info.active) revert IErrors.InactiveAdapter();

            // Validate arrays
            if (v.gauges.length != v.weights.length) revert IErrors.InvalidAmount();

            // Delegate to adapter
            IVotingAdapter(v.adapter).vote(v.gauges, v.weights);
            emit AdapterVoted(v.adapter, v.gauges.length);
        }

        emit VotesExecuted(n);
    }
}
