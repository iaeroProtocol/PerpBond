// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ErrorsEvents.sol";

/**
 * @title AccessRoles
 * @notice Lightweight role-based access control + emergency pause for PerpBond.
 * @dev    Uses shared errors from ErrorsEvents.sol to avoid re-declaration clashes.
 *         - Roles: governor, guardian, keeper, treasury
 *         - Modifiers: onlyGovernor / onlyGuardian / onlyKeeper / whenNotPaused / whenPaused
 *         - Emergency pause (guardian or governor can pause; only governor can unpause)
 *         - Two-step governor transfer (transferGovernorship -> acceptGovernorship)
 *
 * Usage (direct deploy):
 *   contract Vault is AccessRoles {
 *     constructor(address gov, address guard, address keep, address tres)
 *       AccessRoles(gov, guard, keep, tres) {}
 *   }
 *
 * Usage (proxy/initializer):
 *   contract Vault is AccessRoles {
 *     function initialize(address gov, address guard, address keep, address tres) external {
 *       __AccessRoles_init(gov, guard, keep, tres);
 *     }
 *   }
 */
abstract contract AccessRoles is ErrorsEvents {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    address public governor;
    address public guardian;
    address public keeper;
    address public treasury;

    // Two-step governor handover
    address public pendingGovernor;

    // Global pause switch
    bool public paused;

    // Init gate for initializer pattern
    bool private _rolesInitialized;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event RolesInitialized(
        address indexed governor,
        address indexed guardian,
        address indexed keeper,
        address treasury
    );
    event GovernorTransferStarted(address indexed currentGovernor, address indexed pendingGovernor);
    event GovernorAccepted(address indexed previousGovernor, address indexed newGovernor);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event PausedSet(bool paused, address indexed triggeredBy);

    // -----------------------------------------------------------------------
    // Constructor (optional for non-proxied deployments)
    // -----------------------------------------------------------------------
    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_
    ) {
        // For proxied deployments, pass zeros and call __AccessRoles_init in the proxy.
        if (governor_ != address(0)) {
            _initRoles(governor_, guardian_, keeper_, treasury_);
        }
    }

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------
    modifier onlyGovernor() {
        if (msg.sender != governor) revert IErrors.Unauthorized();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert IErrors.Unauthorized();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert IErrors.Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IErrors.Paused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert IErrors.NotPaused();
        _;
    }

    // -----------------------------------------------------------------------
    // Initialization (for proxies)
    // -----------------------------------------------------------------------
    function __AccessRoles_init(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_
    ) internal {
        _initRoles(governor_, guardian_, keeper_, treasury_);
    }

    function _initRoles(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_
    ) private {
        if (_rolesInitialized) revert IErrors.AlreadyInitialized();
        if (
            governor_ == address(0) ||
            guardian_ == address(0) ||
            keeper_ == address(0) ||
            treasury_ == address(0)
        ) revert IErrors.ZeroAddress();

        governor = governor_;
        guardian = guardian_;
        keeper = keeper_;
        treasury = treasury_;
        _rolesInitialized = true;

        emit RolesInitialized(governor_, guardian_, keeper_, treasury_);
    }

    // -----------------------------------------------------------------------
    // Role Management
    // -----------------------------------------------------------------------
    /// @notice Starts two-step transfer of the governor role.
    function transferGovernorship(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert IErrors.ZeroAddress();
        pendingGovernor = newGovernor;
        emit GovernorTransferStarted(governor, newGovernor);
    }

    /// @notice Finalizes the governor transfer; must be called by the pending governor.
    function acceptGovernorship() external {
        if (msg.sender != pendingGovernor) revert IErrors.Unauthorized();
        address oldGov = governor;
        governor = msg.sender;
        pendingGovernor = address(0);
        emit GovernorAccepted(oldGov, governor);
    }

    /// @notice Governor may update the guardian.
    function setGuardian(address newGuardian) external onlyGovernor {
        if (newGuardian == address(0)) revert IErrors.ZeroAddress();
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Governor may update the keeper.
    function setKeeper(address newKeeper) external onlyGovernor {
        if (newKeeper == address(0)) revert IErrors.ZeroAddress();
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @notice Governor may update the treasury address.
    function setTreasury(address newTreasury) external onlyGovernor {
        if (newTreasury == address(0)) revert IErrors.ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    // -----------------------------------------------------------------------
    // Pause
    // -----------------------------------------------------------------------
    /// @notice Guardian or Governor can pause the system (emergency).
    function pause() external {
        // Allow both governor and guardian to trigger a pause.
        if (msg.sender != guardian && msg.sender != governor) revert IErrors.Unauthorized();
        if (paused) revert IErrors.Paused();
        paused = true;
        emit PausedSet(true, msg.sender);
    }

    /// @notice Only Governor can unpause.
    function unpause() external onlyGovernor {
        if (!paused) revert IErrors.NotPaused();
        paused = false;
        emit PausedSet(false, msg.sender);
    }
}
