// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../core/AccessRoles.sol";
import "../core/ErrorsEvents.sol";

/**
 * @title AdapterRegistry
 * @notice Registry of strategy adapters and their safety limits.
 * @dev    - Governor registers/updates adapters and limits.
 *         - Guardian (or Governor) can pause/unpause an adapter.
 *         - Vault/Harvester can read the full list or only active adapters.
 *
 * Struct fields:
 *  - active: whether the adapter can be used right now
 *  - adapter: adapter contract address
 *  - tvlCapUSDC: hard cap for this adapter (USDC, 6 decimals)
 *  - maxBpsOfVault: maximum share of vault TVL the adapter may hold (0..10000)
 *  - maxSlippageBpsOnSwap: per-adapter swap slippage limit (0..10000)
 *  - oracleConfig: opaque bytes for price/oracle configuration (used by OracleLib)
 */
contract AdapterRegistry is AccessRoles, ErrorsEvents {
    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------
    struct AdapterInfo {
        bool active;
        address adapter;
        uint256 tvlCapUSDC;
        uint16 maxBpsOfVault;
        uint16 maxSlippageBpsOnSwap;
        bytes oracleConfig;
    }

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------
    mapping(address => AdapterInfo) private _adapters;
    address[] private _adapterList;

    // -----------------------------------------------------------------------
    // Custom errors (contract-specific)
    // -----------------------------------------------------------------------
    error AdapterAlreadyRegistered();
    error AdapterNotRegistered();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {}

    // -----------------------------------------------------------------------
    // Admin: Register / Update / Pause
    // -----------------------------------------------------------------------

    /// @notice Register a new adapter with initial config. Only Governor.
    function registerAdapter(AdapterInfo calldata info) external onlyGovernor {
        _validateInfo(info);
        if (_exists(info.adapter)) revert AdapterAlreadyRegistered();

        _adapters[info.adapter] = AdapterInfo({
            active: info.active,
            adapter: info.adapter,
            tvlCapUSDC: info.tvlCapUSDC,
            maxBpsOfVault: info.maxBpsOfVault,
            maxSlippageBpsOnSwap: info.maxSlippageBpsOnSwap,
            oracleConfig: info.oracleConfig
        });
        _adapterList.push(info.adapter);

        emit AdapterRegistered(info.adapter);
    }

    /// @notice Update full config for an existing adapter. Only Governor.
    function updateAdapter(AdapterInfo calldata info) external onlyGovernor {
        _validateInfo(info);
        if (!_exists(info.adapter)) revert AdapterNotRegistered();

        _adapters[info.adapter] = AdapterInfo({
            active: info.active,
            adapter: info.adapter,
            tvlCapUSDC: info.tvlCapUSDC,
            maxBpsOfVault: info.maxBpsOfVault,
            maxSlippageBpsOnSwap: info.maxSlippageBpsOnSwap,
            oracleConfig: info.oracleConfig
        });

        emit AdapterUpdated(info.adapter);
    }

    /// @notice Pause/unpause a given adapter. Guardian or Governor.
    function setAdapterActive(address adapter, bool active) external {
        if (msg.sender != guardian && msg.sender != governor) revert IErrors.Unauthorized();
        if (!_exists(adapter)) revert AdapterNotRegistered();

        _adapters[adapter].active = active;
        emit AdapterPaused(adapter, active);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @notice Return config for a given adapter.
    function getAdapter(address adapter) external view returns (AdapterInfo memory) {
        if (!_exists(adapter)) revert AdapterNotRegistered();
        return _adapters[adapter];
    }

    /// @notice Return configs for all known adapters (active and inactive).
    /// @dev    The `adapter` address is included in each element.
    function list() external view returns (AdapterInfo[] memory all) {
        uint256 n = _adapterList.length;
        all = new AdapterInfo[](n);
        for (uint256 i = 0; i < n; ++i) {
            address a = _adapterList[i];
            all[i] = _adapters[a];
        }
    }

    /// @notice Return only active adapter addresses (for Vault/Harvester loops).
    function getActiveAdapters() external view returns (address[] memory addrs) {
        uint256 n = _adapterList.length;
        uint256 c;
        // First pass: count actives
        for (uint256 i = 0; i < n; ++i) {
            if (_adapters[_adapterList[i]].active) ++c;
        }
        // Second pass: collect actives
        addrs = new address[](c);
        uint256 j;
        for (uint256 i = 0; i < n; ++i) {
            address a = _adapterList[i];
            if (_adapters[a].active) {
                addrs[j++] = a;
            }
        }
    }

    /// @notice Total number of adapters ever registered (active + inactive).
    function adaptersCount() external view returns (uint256) {
        return _adapterList.length;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------
    function _exists(address adapter) private view returns (bool) {
        return _adapters[adapter].adapter != address(0);
    }

    function _validateInfo(AdapterInfo calldata info) private pure {
        if (info.adapter == address(0)) revert IErrors.ZeroAddress();
        if (info.maxBpsOfVault > BPS_DENOMINATOR) revert IErrors.InvalidAmount();
        if (info.maxSlippageBpsOnSwap > BPS_DENOMINATOR) revert IErrors.InvalidAmount();
        // tvlCapUSDC can be zero to indicate "no cap" if you prefer; enforced at Vault/Harvester.
    }
}
