// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./AccessRoles.sol";
import "./ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";
import "../libs/MathLib.sol";
import "./PerpBondVault.sol";
import "./PerpBondToken.sol";

/// @notice Minimal interface for Harvester's transfer function (security fix: no infinite approvals)
interface IHarvester {
    function transferToDistributor(uint256 amount) external returns (uint256);
    function usdcBalance() external view returns (uint256);
}

/**
 * @title Distributor
 * @notice Accumulates harvested USDC and distributes it to PerpBond receipt holders by epoch.
 *         Users can claim to wallet or, if they enabled it on the Vault, auto‑compound into new shares.
 *
 * Important notes:
 * - This minimal version computes claims using the user's *current* receipt balance and the
 *   per‑epoch USDC‑per‑share index. It's simple and matches the current frontend, but it is not
 *   transfer‑aware (i.e., it does not snapshot balances at each epoch). Good for MVP; upgrade later
 *   if you need exact epoch snapshots. :contentReference[oaicite:3]{index=3}
 */
contract Distributor is AccessRoles, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    // -----------------------------------------------------------------------
    // Core state
    // -----------------------------------------------------------------------
    PerpBondVault public immutable vault;
    PerpBondToken  public immutable receipt; // share token (18 decimals)
    IERC20         public immutable usdc;    // asset token (6 decimals)

    // Optional harvester that holds harvested USDC between epochs.
    address public harvester;

    // Performance fee (in BPS) taken from each epoch before distribution.
    uint16 public feeBps; // e.g., 1000 = 10%

    // Carryover if an epoch is closed when there are no shares (distributed later).
    uint256 public pendingUsdc;

    // Epoch counter (next epoch id to write).
    uint256 public currentEpoch;

    // SECURITY FIX C-5: Max epochs to process in a single claim to prevent gas DoS
    uint256 public constant MAX_EPOCHS_PER_CLAIM = 50;

    struct Epoch {
        uint64  timestamp;        // close time
        uint256 totalUsdc;        // net USDC distributed this epoch (after fees)
        uint256 totalShares;      // vault receipt total supply at close
        uint256 usdcPerShareRay;  // dimensionless ratio in 1e27 (see MathLib.usdcPerShareRay)
    }

    mapping(uint256 => Epoch) public epochs;
    // For each user, the next epoch index they will start claiming from.
    mapping(address => uint256) public lastClaimedEpoch;

    // -----------------------------------------------------------------------
    // Events (from ErrorsEvents)
    // - event YieldHarvested(uint256 indexed epoch, uint256 usdc);
    // - event EpochClosed(uint256 indexed epoch, uint256 netUsdc, uint256 totalShares, uint256 usdcPerShareRay);
    // - event Claimed(address indexed user, uint256 usdcAmount, bool autoCompounded);
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address vault_,
        address harvester_,
        uint16 feeBps_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (vault_ == address(0)) revert IErrors.ZeroAddress();
        vault = PerpBondVault(vault_);
        receipt = vault.receipt();
        usdc = IERC20(address(vault.usdc()));

        harvester = harvester_;
        _setFeeBps(feeBps_);
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------
    function setHarvester(address newHarvester) external onlyGovernor {
        harvester = newHarvester; // allow zero to disable pulling
    }

    function setFeeBps(uint16 newFeeBps) external onlyGovernor {
        _setFeeBps(newFeeBps);
    }

    function _setFeeBps(uint16 newFeeBps) internal {
        if (newFeeBps > 10_000) revert IErrors.InvalidAmount();
        feeBps = newFeeBps;
    }

    /// @notice Rescue any ERC‑20 mistakenly sent here.
    function rescueToken(address token, address to, uint256 amount) external onlyGovernor {
        if (token == address(0) || to == address(0)) revert IErrors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // -----------------------------------------------------------------------
    // Keeper: close & record an epoch
    // -----------------------------------------------------------------------

    /// @notice Close the current epoch: pull harvested USDC from the harvester, take fee, record distribution.
    /// @dev    SECURITY FIX: Uses transferToDistributor() instead of transferFrom to avoid infinite approvals.
    function closeEpoch() external onlyKeeper nonReentrant whenNotPaused {
        uint256 harvested;
        if (harvester != address(0)) {
            uint256 bal = IHarvester(harvester).usdcBalance();
            if (bal > 0) {
                // Pull funds via Harvester's permissioned transfer (no approval needed).
                harvested = IHarvester(harvester).transferToDistributor(bal);
            }
        }

        uint256 amount = pendingUsdc + harvested;
        if (amount == 0) {
            // Nothing to distribute; skip creating an empty epoch.
            return;
        }

        // If no shares exist yet, carry everything forward (don't take fees yet).
        uint256 totalShares = receipt.totalSupply();
        if (totalShares == 0) {
            pendingUsdc = amount;
            emit YieldHarvested(currentEpoch, amount);
            return;
        }

        // Clear carry; now we can distribute.
        pendingUsdc = 0;

        // Take performance fee and send to treasury.
        uint256 fee = MathLib.mulBps(amount, feeBps);
        uint256 net = amount - fee;
        if (fee > 0) usdc.safeTransfer(treasury, fee);

        // Record epoch accounting.
        uint256 ratio = MathLib.usdcPerShareRay(net, totalShares);
        epochs[currentEpoch] = Epoch({
            timestamp: uint64(block.timestamp),
            totalUsdc: net,
            totalShares: totalShares,
            usdcPerShareRay: ratio
        });

        emit YieldHarvested(currentEpoch, amount);
        emit EpochClosed(currentEpoch, net, totalShares, ratio);

        unchecked {
            ++currentEpoch;
        }
    }

    // -----------------------------------------------------------------------
    // User claims
    // -----------------------------------------------------------------------

    /// @notice Return total claimable USDC (6 decimals) for `user` across unclaimed epochs.
    /// @dev SECURITY FIX C-5: Limited to MAX_EPOCHS_PER_CLAIM to prevent gas DoS
    function claimableUSDC(address user) public view returns (uint256) {
        uint256 start = lastClaimedEpoch[user];
        uint256 end = currentEpoch;
        if (start >= end) return 0;

        uint256 userShares = receipt.balanceOf(user);
        if (userShares == 0) return 0;

        // Cap the number of epochs we process to prevent gas DoS
        if (end - start > MAX_EPOCHS_PER_CLAIM) {
            end = start + MAX_EPOCHS_PER_CLAIM;
        }

        // Sum in WAD to keep precision, convert to USDC (6) at the end.
        uint256 sumWad;
        for (uint256 i = start; i < end; ++i) {
            uint256 ray = epochs[i].usdcPerShareRay;
            if (ray == 0) continue;
            // shares(1e18) * ray(1e27) / 1e27 => WAD(1e18)
            sumWad += (userShares * ray) / 1e27;
        }
        return MathLib.wadToUsdc(sumWad);
    }

    /// @notice Claim all available USDC (up to MAX_EPOCHS_PER_CLAIM). If the user enabled auto‑compound on the Vault,
    ///         the USDC is deposited back into the Vault for new shares.
    /// @dev SECURITY FIX C-5: Users must call multiple times if they have > MAX_EPOCHS_PER_CLAIM unclaimed
    function claim() external nonReentrant whenNotPaused returns (uint256 claimed) {
        address user = msg.sender;

        claimed = claimableUSDC(user);

        // SECURITY FIX C-5: Only advance cursor by epochs actually processed
        uint256 start = lastClaimedEpoch[user];
        uint256 end = currentEpoch;
        if (end - start > MAX_EPOCHS_PER_CLAIM) {
            end = start + MAX_EPOCHS_PER_CLAIM;
        }
        lastClaimedEpoch[user] = end;

        if (claimed == 0) {
            emit Claimed(user, 0, false);
            return 0;
        }

        bool ac = vault.autoCompoundOf(user);
        if (ac) {
            // Approve and re‑deposit to the Vault on behalf of the user.
            usdc.safeApprove(address(vault), 0);          // reset for safety with stubborn tokens
            usdc.safeApprove(address(vault), claimed);
            vault.deposit(claimed, user);
            emit Claimed(user, claimed, true);
        } else {
            usdc.safeTransfer(user, claimed);
            emit Claimed(user, claimed, false);
        }
    }

    // -----------------------------------------------------------------------
    // Views for UI convenience
    // -----------------------------------------------------------------------

    /// @notice Number of closed epochs.
    function epochsCount() external view returns (uint256) {
        return currentEpoch;
    }
}
