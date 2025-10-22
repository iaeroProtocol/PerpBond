// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./AccessRoles.sol";
import "./ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";
import "../libs/MathLib.sol";
import "./PerpBondToken.sol";
import "../adapters/AdapterRegistry.sol";
import "../adapters/IStrategyAdapter.sol";

/**
 * @title PerpBondVault
 * @notice USDC-in / receipt-shares out (no redemptions). Idle USDC is periodically
 *         deployed across active adapters per governor-set target allocations.
 *         Distributor reads users' auto-compound preference via autoCompoundOf().
 */
contract PerpBondVault is AccessRoles, ErrorsEvents, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    uint16 public constant BPS_DENOMINATOR = 10_000;

    // SECURITY FIX C-6: Minimum deployment efficiency (95% = 9500 bps)
    // If adapter reports less than 95% deployed, revert to prevent losses
    uint16 public minDeploymentBps = 9500;

    // -----------------------------------------------------------------------
    // Core state
    // -----------------------------------------------------------------------
    IERC20 public immutable usdc;           // 6 decimals
    PerpBondToken public immutable receipt; // 18 decimals (the share token)
    AdapterRegistry public registry;

    // Idle USDC held in the vault (awaiting deployment to adapters)
    uint256 public idleUsdc;

    // Governor-defined target allocations (bps per adapter address).
    // Sum across ACTIVE adapters must be 10_000 (100%) before rebalance().
    mapping(address => uint16) public targetAllocationBps;

    // Per-user auto-compound preference (read by Distributor on claim()).
    mapping(address => bool) private _autoCompound;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address usdc_,
        address receiptToken_,
        address registry_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (usdc_ == address(0) || receiptToken_ == address(0) || registry_ == address(0)) {
            revert IErrors.ZeroAddress();
        }
        usdc = IERC20(usdc_);
        receipt = PerpBondToken(receiptToken_);
        registry = AdapterRegistry(registry_);
    }

    // -----------------------------------------------------------------------
    // User actions
    // -----------------------------------------------------------------------

    /// @notice Deposit USDC and mint receipt shares to msg.sender.
    function deposit(uint256 assets) external returns (uint256 shares) {
        return deposit(assets, msg.sender);
    }

    /// @notice Deposit USDC and mint receipt shares to `receiver`.
    /// @dev    ERC-4626-style conversion; uses pre-deposit NAV for share calc.
    function deposit(uint256 assets, address receiver)
        public
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0 || receiver == address(0)) revert IErrors.InvalidAmount();

        // Snapshot NAV & supply BEFORE assets arrive.
        uint256 taBefore = totalAssets();
        uint256 tsBefore = receipt.totalSupply();

        // Pull funds in and account as idle.
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        idleUsdc += assets;

        // Calculate shares and mint.
        shares = MathLib.convertToShares(assets, taBefore, tsBefore);
        if (shares == 0) revert IErrors.InvalidAmount();

        receipt.mint(receiver, shares);
        emit Deposited(receiver, assets, shares);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @notice Total USDC-equivalent value (idle + all adapters).
    function totalAssets() public view returns (uint256) {
        uint256 total = idleUsdc;

        address[] memory adapters = registry.getActiveAdapters();
        uint256 n = adapters.length;
        for (uint256 i = 0; i < n; ++i) {
            total += IStrategyAdapter(adapters[i]).tvl();
        }
        return total;
    }

    /// @notice Expose receipt token total supply for convenience (UI/SDK).
    function totalSupply() external view returns (uint256) {
        return receipt.totalSupply();
    }

    /// @notice Convert USDC (6) to shares (18) at current NAV.
    function convertToShares(uint256 assets) external view returns (uint256) {
        return MathLib.convertToShares(assets, totalAssets(), receipt.totalSupply());
    }

    /// @notice Convert shares (18) to USDC (6) at current NAV.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return MathLib.convertToAssets(shares, totalAssets(), receipt.totalSupply());
    }

    // -----------------------------------------------------------------------
    // Auto-compound preference (read by Distributor)
    // -----------------------------------------------------------------------

    function autoCompoundOf(address user) external view returns (bool) {
        return _autoCompound[user];
    }

    function setAutoCompound(bool on) external whenNotPaused {
        _autoCompound[msg.sender] = on;
        emit AutoCompoundSet(msg.sender, on);
    }

    // -----------------------------------------------------------------------
    // Allocation management
    // -----------------------------------------------------------------------

    /// @notice Governor sets target allocation bps for active adapters.
    /// @dev    Clears previous targets for all ACTIVE adapters first.
    function setTargetAllocations(address[] calldata adapters, uint16[] calldata bps)
        external
        onlyGovernor
    {
        if (adapters.length != bps.length) revert IErrors.InvalidAmount();

        // Clear existing targets for currently active adapters
        address[] memory active = registry.getActiveAdapters();
        for (uint256 i = 0; i < active.length; ++i) {
            targetAllocationBps[active[i]] = 0;
        }

        // Set new targets, checking registry presence as we go
        uint256 sum;
        for (uint256 i = 0; i < adapters.length; ++i) {
            // Will revert if adapter is unknown
            AdapterRegistry.AdapterInfo memory info = registry.getAdapter(adapters[i]);
            if (!info.active) revert IErrors.InactiveAdapter();
            if (bps[i] > BPS_DENOMINATOR) revert IErrors.InvalidAmount();

            targetAllocationBps[adapters[i]] = bps[i];
            sum += bps[i];
        }
        if (sum != BPS_DENOMINATOR) revert IErrors.AllocationSumNot10000();
    }

    // -----------------------------------------------------------------------
    // Keeper: deploy idle USDC across adapters according to targets
    // -----------------------------------------------------------------------

    /// @notice Deploy `idleUsdc` across active adapters according to targetAllocationBps.
    ///         Enforces per-adapter TVL caps and max % of vault TVL from the registry.
    function rebalance() external onlyKeeper nonReentrant whenNotPaused {
        uint256 toDeploy = idleUsdc;
        if (toDeploy == 0) {
            emit Rebalanced(0, idleUsdc);
            return;
        }

        address[] memory active = registry.getActiveAdapters();
        uint256 n = active.length;

        // Sum target bps across ACTIVE adapters and require 100%.
        uint256 sumBps;
        for (uint256 i = 0; i < n; ++i) {
            sumBps += targetAllocationBps[active[i]];
        }
        if (sumBps != BPS_DENOMINATOR) revert IErrors.AllocationSumNot10000();

        uint256 taBefore = totalAssets(); // includes current idle
        uint256 deployed;

        for (uint256 i = 0; i < n; ++i) {
            address adapter = active[i];

            // Desired slice from this deployment batch.
            uint256 desired = (toDeploy * targetAllocationBps[adapter]) / BPS_DENOMINATOR;
            if (desired == 0) continue;

            // Enforce registry limits.
            AdapterRegistry.AdapterInfo memory info = registry.getAdapter(adapter);
            uint256 current = IStrategyAdapter(adapter).tvl();

            // Cap 1: hard USDC TVL cap for this adapter.
            if (info.tvlCapUSDC > 0) {
                uint256 capacity = info.tvlCapUSDC > current ? info.tvlCapUSDC - current : 0;
                if (desired > capacity) desired = capacity;
            }

            // Cap 2: max % of vault TVL.
            if (info.maxBpsOfVault > 0) {
                uint256 allowed = (taBefore * info.maxBpsOfVault) / BPS_DENOMINATOR;
                if (current >= allowed) {
                    desired = 0;
                } else {
                    uint256 remaining = allowed - current;
                    if (desired > remaining) desired = remaining;
                }
            }

            if (desired == 0) continue;

            // Transfer and deploy.
            usdc.safeTransfer(adapter, desired);
            uint256 deployedThis = IStrategyAdapter(adapter).deposit(desired);

            // SECURITY FIX C-6: Validate minimum deployment efficiency
            uint256 minExpected = (desired * minDeploymentBps) / BPS_DENOMINATOR;
            if (deployedThis < minExpected) revert IErrors.SlippageTooHigh();

            // Be conservative: if adapter reports less deployed, count that.
            if (deployedThis > desired) deployedThis = desired;
            deployed += deployedThis;
        }

        if (deployed > idleUsdc) deployed = idleUsdc; // defensive
        idleUsdc -= deployed;

        emit Rebalanced(deployed, idleUsdc);
    }

    // -----------------------------------------------------------------------
    // Admin utilities
    // -----------------------------------------------------------------------

    /// @notice Governor may update the registry address.
    function setRegistry(address newRegistry) external onlyGovernor {
        if (newRegistry == address(0)) revert IErrors.ZeroAddress();
        registry = AdapterRegistry(newRegistry);
    }

    /// @notice SECURITY FIX C-6: Set minimum deployment efficiency (default 9500 = 95%)
    function setMinDeploymentBps(uint16 newMin) external onlyGovernor {
        if (newMin < 9000 || newMin > BPS_DENOMINATOR) revert IErrors.InvalidAmount();
        minDeploymentBps = newMin;
    }

    /// @notice SECURITY FIX H-2: Emergency withdrawal from all adapters
    /// @dev Only Governor or Guardian can trigger. Calls emergencyWithdraw() on all adapters.
    function emergencyWithdrawAll() external nonReentrant returns (uint256 totalRecovered) {
        if (msg.sender != governor && msg.sender != guardian) revert IErrors.Unauthorized();

        address[] memory adapters = registry.getActiveAdapters();
        uint256 n = adapters.length;

        for (uint256 i = 0; i < n; ++i) {
            try IStrategyAdapter(adapters[i]).emergencyWithdraw() returns (uint256 recovered) {
                totalRecovered += recovered;
            } catch {
                // Continue even if one adapter fails
                continue;
            }
        }

        // Add any idle USDC already in vault
        totalRecovered += idleUsdc;
    }
}
