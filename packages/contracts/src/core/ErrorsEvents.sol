// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ErrorsEvents
 * @notice Centralized error & event declarations for the PerpBond system.
 *
 * Design notes
 * - Errors are namespaced under the IErrors interface (use `revert IErrors.X()`),
 *   which avoids identifier collisions with contracts that already declared
 *   their own error names (e.g., AccessRoles).
 * - Events are declared under IEvents; inherit `ErrorsEvents` (which implements
 *   both interfaces) so you can `emit Deposit(...)` etc. without namespacing.
 *
 * Example usage:
 *   import {  IErrors } from "./ErrorsEvents.sol";
 *
 *   contract PerpBondVault is ErrorsEvents {
 *     function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
 *       if (assets == 0 || receiver == address(0)) revert IErrors.InvalidAmount();
 *       // ...
 *       emit Deposited(receiver, assets, shares);
 *     }
 *   }
 */

/* /////////////////////////////////////////////////////////////////////////////
                                    Errors
///////////////////////////////////////////////////////////////////////////// */
interface IErrors {
    // Generic
    error Unauthorized();
    error ZeroAddress();
    error AlreadyInitialized();
    error Paused();
    error NotPaused();
    error InvalidAmount();

    // Registry / allocation
    error CapExceeded();                 // adapter or vault cap hit
    error InactiveAdapter();             // adapter not active in registry
    error AllocationSumNot10000();       // target BPS must sum to 10000

    // Swap/harvest guards
    error RouterNotAllowed();
    error SlippageTooHigh();
    error OracleOutOfBounds();

    // Token ops
    error TransferFailed();
    error ApproveFailed();
}

/* /////////////////////////////////////////////////////////////////////////////
                                    Events
///////////////////////////////////////////////////////////////////////////// */
interface IEvents {
    // ----- Vault lifecycle -----
    /// @notice Emitted on user deposits (USDC in → receipt shares out).
    event Deposited(address indexed user, uint256 usdc, uint256 shares);

    /// @notice Emitted when keeper deploys idle USDC across adapters.
    event Rebalanced(uint256 deployedUsdc, uint256 idleLeft);

    /// @notice Per-user preference toggled (read by Distributor during claim).
    event AutoCompoundSet(address indexed user, bool on);

    // ----- Yield / distribution cycle -----
    /// @notice Emitted when rewards are harvested and realized as USDC (pre-fee, per epoch).
    event YieldHarvested(uint256 indexed epoch, uint256 usdc);

    /// @notice Emitted when an epoch is closed and distribution math is finalized.
    event EpochClosed(uint256 indexed epoch, uint256 netUsdc, uint256 totalShares, uint256 usdcPerShareRay);

    /// @notice Emitted on user claims (cash out to user or auto-compound back into vault).
    event Claimed(address indexed user, uint256 usdcAmount, bool autoCompounded);

    // ----- Registry / adapters -----
    event AdapterRegistered(address indexed adapter);
    event AdapterUpdated(address indexed adapter);
    event AdapterPaused(address indexed adapter, bool active);
}

/* /////////////////////////////////////////////////////////////////////////////
                              Convenience Base Contract
///////////////////////////////////////////////////////////////////////////// */
abstract contract ErrorsEvents is IErrors, IEvents {}
