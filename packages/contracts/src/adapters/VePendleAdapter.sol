// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../core/AccessRoles.sol";
import "../core/ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";
import "./IStrategyAdapter.sol";
import "./ILockingAdapter.sol";
import "./IVotingAdapter.sol";
import "../core/RouterGuard.sol";
import "../interfaces/external/IPendleVoting.sol";

/**
 * @title VePendleAdapter
 * @notice SECURITY IMPLEMENTATION (C-2): Adapter for locking PENDLE → vePENDLE
 * @dev One of the three core yield strategies (alongside veAERO and vlCVX)
 *
 * Strategy:
 * 1. Swap USDC → PENDLE on Uniswap V3
 * 2. Lock PENDLE → vePENDLE for voting power
 * 3. Vote on Pendle gauges weekly
 * 4. Harvest rewards (vlPENDLE emissions, bribes, fees)
 * 5. Swap rewards → USDC
 *
 * NOTE: This is an initial implementation. In production, integrate with:
 * - Pendle VotingEscrow contract for locking
 * - Pendle GaugeController for voting
 * - Pendle FeeDistributor for reward claims
 */
contract VePendleAdapter is
    AccessRoles,
    
    ReentrancyGuard,
    IStrategyAdapter,
    ILockingAdapter,
    IVotingAdapter
{
    using SafeTransferLib for IERC20;

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------
    IERC20 public immutable usdc;      // 6 decimals
    IERC20 public immutable pendle;    // underlying
    address public immutable vault;    // vault is the only caller of deposit()

    // -----------------------------------------------------------------------
    // External Contracts
    // -----------------------------------------------------------------------
    address public swapRouter;         // Uniswap V3 router for USDC→PENDLE
    RouterGuard public guard;          // RouterGuard for oracle validation
    address public harvester;          // allowed caller for harvest()
    address public voterRouter;        // allowed caller for vote()

    IPendleVotingEscrow public pendleVotingEscrow; // vePENDLE locking contract
    IPendleGaugeController public pendleGaugeController; // Voting contract
    IPendleFeeDistributor public pendleFeeDistributor; // Rewards contract

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    uint256 public lockDuration = 104 weeks; // 2 years (max lock)
    uint256 public lockExpiryTimestamp;      // When current lock expires

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event PendleLocked(uint256 amount, uint256 expiryTimestamp);
    event PendleAmountIncreased(uint256 amount);
    event RewardsClaimed(uint256 usdcValue);
    event LockExtended(uint256 newExpiry);
    event VoteCast(address[] gauges, uint256[] weights);
    event PendleContractsSet(address votingEscrow, address gaugeController, address feeDistributor);
    event SwapRouterSet(address indexed router);
    event GuardSet(address indexed guard);

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address vault_,
        address usdc_,
        address pendle_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (vault_ == address(0) || usdc_ == address(0) || pendle_ == address(0)) {
            revert IErrors.ZeroAddress();
        }

        vault = vault_;
        usdc = IERC20(usdc_);
        pendle = IERC20(pendle_);
    }

    // -----------------------------------------------------------------------
    // Admin Configuration
    // -----------------------------------------------------------------------

    function setSwapRouter(address newRouter) external onlyGovernor {
        swapRouter = newRouter;
        emit SwapRouterSet(newRouter);
    }

    function setGuard(address newGuard) external onlyGovernor {
        guard = RouterGuard(newGuard);
        emit GuardSet(newGuard);
    }

    function setHarvester(address newHarvester) external onlyGovernor {
        harvester = newHarvester;
    }

    function setVoterRouter(address newRouter) external onlyGovernor {
        voterRouter = newRouter;
    }

    function setPendleContracts(
        address votingEscrow_,
        address gaugeController_,
        address feeDistributor_
    ) external onlyGovernor {
        if (votingEscrow_ != address(0)) pendleVotingEscrow = IPendleVotingEscrow(votingEscrow_);
        if (gaugeController_ != address(0)) pendleGaugeController = IPendleGaugeController(gaugeController_);
        if (feeDistributor_ != address(0)) pendleFeeDistributor = IPendleFeeDistributor(feeDistributor_);
        emit PendleContractsSet(votingEscrow_, gaugeController_, feeDistributor_);
    }

    function setLockDuration(uint256 newDuration) external onlyGovernor {
        if (newDuration < 52 weeks || newDuration > 104 weeks) revert IErrors.InvalidAmount();
        lockDuration = newDuration;
    }

    // -----------------------------------------------------------------------
    // IStrategyAdapter Implementation
    // -----------------------------------------------------------------------

    /**
     * @notice Vault transfers USDC, adapter swaps to PENDLE and locks
     */
    function deposit(uint256 usdcAmount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 deployedUsdc)
    {
        if (msg.sender != vault) revert IErrors.Unauthorized();
        if (usdcAmount == 0) revert IErrors.InvalidAmount();

        uint256 bal = usdc.balanceOf(address(this));
        if (usdcAmount > bal) usdcAmount = bal;

        // NOTE: In production, implement USDC→PENDLE swap via Uniswap V3
        // Then lock PENDLE to vePENDLE:
        /*
        // 1. Swap USDC → PENDLE using swapRouter
        usdc.safeApprove(swapRouter, 0);
        usdc.safeApprove(swapRouter, usdcAmount);
        uint256 pendleOut = ISwapRouter(swapRouter).exactInputSingle(...);

        // 2. Lock PENDLE → vePENDLE
        pendle.safeApprove(pendleVotingEscrow, 0);
        pendle.safeApprove(pendleVotingEscrow, pendleOut);

        uint256 unlockTime = block.timestamp + lockDuration;
        IVotingEscrow(pendleVotingEscrow).create_lock(pendleOut, unlockTime);
        lockExpiryTimestamp = unlockTime;

        emit PendleLocked(pendleOut, unlockTime);
        */

        return usdcAmount; // Deployed notionally equals USDC contributed
    }

    /**
     * @notice Harvest vePENDLE rewards and swap to USDC
     */
    function harvest() external override nonReentrant returns (uint256 estimatedUsdcOut) {
        if (msg.sender != harvester && msg.sender != keeper) revert IErrors.Unauthorized();

        // NOTE: In production, implement:
        // 1. Claim vePENDLE emissions from FeeDistributor
        // 2. Claim any bribes from third-party protocols
        // 3. Swap all reward tokens → USDC via configured swapper
        // 4. Transfer USDC to Harvester

        /*
        if (pendleFeeDistributor != address(0)) {
            uint256[] memory rewards = IFeeDistributor(pendleFeeDistributor).claim();
            // Process and swap rewards
        }
        */

        return 0; // Placeholder
    }

    /**
     * @notice TVL in USDC terms = locked PENDLE value (via oracle)
     */
    function tvl() external view override returns (uint256) {
        uint256 pendleBalance = pendle.balanceOf(address(this));

        // NOTE: In production, query vePENDLE balance and convert via oracle
        /*
        if (pendleVotingEscrow != address(0)) {
            uint256 lockedPendle = IVotingEscrow(pendleVotingEscrow).locked(address(this));
            // Convert to USDC via oracle/guard
        }
        */

        return 0; // Placeholder - implement oracle conversion
    }

    /**
     * @notice Emergency unwind: unlock if possible, swap to USDC, return to vault
     */
    function emergencyWithdraw() external override nonReentrant returns (uint256 recoveredUsdc) {
        if (msg.sender != governor && msg.sender != guardian) revert IErrors.Unauthorized();

        // NOTE: vePENDLE locks are non-transferable and time-locked
        // Emergency withdrawal can only recover:
        // 1. Unlocked PENDLE (if lock expired)
        // 2. Pending rewards
        // 3. Idle USDC

        /*
        if (block.timestamp >= lockExpiryTimestamp && pendleVotingEscrow != address(0)) {
            IVotingEscrow(pendleVotingEscrow).withdraw();
            uint256 pendleBal = pendle.balanceOf(address(this));
            // Swap PENDLE → USDC
        }
        */

        recoveredUsdc = usdc.balanceOf(address(this));
        if (recoveredUsdc > 0) {
            usdc.safeTransfer(vault, recoveredUsdc);
        }
    }

    function name() external pure override returns (string memory) {
        return "Pendle vePENDLE";
    }

    function underlyingToken() external view override returns (address) {
        return address(pendle);
    }

    // -----------------------------------------------------------------------
    // ILockingAdapter Implementation
    // -----------------------------------------------------------------------

    function lockedUntil() external view override returns (uint256) {
        return lockExpiryTimestamp;
    }

    // -----------------------------------------------------------------------
    // IVotingAdapter Implementation
    // -----------------------------------------------------------------------

    /**
     * @notice Vote on Pendle gauges with vePENDLE voting power
     * @param gauges Array of gauge addresses to vote for
     * @param weights Array of weights (in basis points, max 10000 per gauge)
     */
    function vote(address[] calldata gauges, uint256[] calldata weights) external override {
        if (msg.sender != voterRouter && msg.sender != keeper) revert IErrors.Unauthorized();
        if (gauges.length != weights.length) revert IErrors.InvalidAmount();
        if (address(pendleGaugeController) == address(0)) revert IErrors.ZeroAddress();

        // Vote on each gauge with the specified weight
        for (uint256 i = 0; i < gauges.length; i++) {
            pendleGaugeController.vote_for_gauge_weights(gauges[i], weights[i]);
        }

        emit VoteCast(gauges, weights);
    }

    // -----------------------------------------------------------------------
    // vePENDLE Operations
    // -----------------------------------------------------------------------

    /**
     * @notice Create a new vePENDLE lock
     * @param amount Amount of PENDLE to lock
     * @param unlockTime Unix timestamp when lock expires (must be rounded to weeks, max 2 years)
     */
    function createLock(uint256 amount, uint128 unlockTime) external onlyKeeper whenNotPaused nonReentrant {
        if (amount == 0) revert IErrors.InvalidAmount();
        if (address(pendleVotingEscrow) == address(0)) revert IErrors.ZeroAddress();

        uint256 pendleBal = pendle.balanceOf(address(this));
        if (amount > pendleBal) amount = pendleBal;

        pendle.safeApprove(address(pendleVotingEscrow), 0);
        pendle.safeApprove(address(pendleVotingEscrow), amount);

        pendleVotingEscrow.create_lock(amount, unlockTime);
        lockExpiryTimestamp = unlockTime;

        emit PendleLocked(amount, unlockTime);
    }

    /**
     * @notice Increase the amount locked in vePENDLE
     * @param amount Additional PENDLE to lock
     */
    function increaseAmount(uint256 amount) external onlyKeeper whenNotPaused nonReentrant {
        if (amount == 0) revert IErrors.InvalidAmount();
        if (address(pendleVotingEscrow) == address(0)) revert IErrors.ZeroAddress();

        uint256 pendleBal = pendle.balanceOf(address(this));
        if (amount > pendleBal) amount = pendleBal;

        pendle.safeApprove(address(pendleVotingEscrow), 0);
        pendle.safeApprove(address(pendleVotingEscrow), amount);

        pendleVotingEscrow.increase_amount(amount);

        emit PendleAmountIncreased(amount);
    }

    /**
     * @notice Extend the unlock time for vePENDLE
     * @param newUnlockTime New unlock timestamp (must be > current, rounded to weeks)
     */
    function increaseUnlockTime(uint128 newUnlockTime) external onlyKeeper whenNotPaused nonReentrant {
        if (address(pendleVotingEscrow) == address(0)) revert IErrors.ZeroAddress();
        if (newUnlockTime <= lockExpiryTimestamp) revert IErrors.InvalidAmount();

        pendleVotingEscrow.increase_unlock_time(newUnlockTime);
        lockExpiryTimestamp = newUnlockTime;

        emit LockExtended(newUnlockTime);
    }

    /**
     * @notice Withdraw from an expired vePENDLE lock
     */
    function withdrawLock() external onlyKeeper nonReentrant {
        if (address(pendleVotingEscrow) == address(0)) revert IErrors.ZeroAddress();
        if (block.timestamp < lockExpiryTimestamp) revert IErrors.InvalidAmount(); // Lock not expired

        pendleVotingEscrow.withdraw();
        lockExpiryTimestamp = 0;
    }

    /**
     * @notice Claim vePENDLE rewards from fee distributor
     */
    function claimRewards() external onlyKeeper whenNotPaused nonReentrant returns (uint256 claimed) {
        if (address(pendleFeeDistributor) == address(0)) revert IErrors.ZeroAddress();

        claimed = pendleFeeDistributor.claim(address(this));
        emit RewardsClaimed(claimed);
    }

    /**
     * @notice Get locked balance information
     * @return amount Locked amount
     * @return expiry Lock expiry timestamp
     */
    function getLockedBalance() external view returns (uint128 amount, uint128 expiry) {
        if (address(pendleVotingEscrow) == address(0)) return (0, 0);

        IPendleVotingEscrow.LockedBalance memory locked = pendleVotingEscrow.locked(address(this));
        return (locked.amount, locked.expiry);
    }

    /**
     * @notice Get voting power balance
     * @return Voting power
     */
    function getVotingPower() external view returns (uint256) {
        if (address(pendleVotingEscrow) == address(0)) return 0;
        return pendleVotingEscrow.balanceOf(address(this));
    }

    // -----------------------------------------------------------------------
    // Emergency Recovery
    // -----------------------------------------------------------------------

    function rescueToken(address token, address to, uint256 amount) external onlyGovernor {
        if (token == address(0) || to == address(0)) revert IErrors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }
}
