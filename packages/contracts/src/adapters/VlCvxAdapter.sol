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
import "../interfaces/external/IConvexVoting.sol";

/**
 * @title VlCvxAdapter
 * @notice SECURITY IMPLEMENTATION (C-2): Adapter for locking CVX → vlCVX (vote-locked Convex)
 * @dev One of the three core yield strategies (alongside veAERO and vePENDLE)
 *
 * Strategy:
 * 1. Swap USDC → CVX on Uniswap V3
 * 2. Lock CVX → vlCVX for voting power (16-week epochs)
 * 3. Vote on Convex gauges for bribe incentives
 * 4. Harvest rewards (cvxCRV, bribes, platform fees)
 * 5. Swap rewards → USDC
 *
 * NOTE: This is an initial implementation. In production, integrate with:
 * - Convex CvxLockerV2 contract for locking
 * - Convex Snapshot/on-chain voting for gauge votes
 * - Convex reward pools for claiming
 */
contract VlCvxAdapter is
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
    IERC20 public immutable cvx;       // Convex token (18 decimals)
    address public immutable vault;    // vault is the only caller of deposit()

    // -----------------------------------------------------------------------
    // External Contracts
    // -----------------------------------------------------------------------
    address public swapRouter;         // Uniswap V3 router for USDC→CVX
    RouterGuard public guard;          // RouterGuard for oracle validation
    address public harvester;          // allowed caller for harvest()
    address public voterRouter;        // allowed caller for vote()

    ICvxLocker public cvxLocker;       // CvxLockerV2 (vlCVX locking contract)
    ICvxVoteProxy public voteProxy;    // Convex vote proxy for gauge voting
    address public cvxRewardPool;      // cvxCRV rewards pool
    address public cvxCrv;             // cvxCRV token

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    uint256 public lockEpoch;          // Current lock epoch
    uint256 public nextUnlockTimestamp; // When next batch unlocks

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event CvxLocked(uint256 amount, uint256 lockEpoch);
    event RewardsClaimed(uint256[] amounts, address[] tokens);
    event VoteCast(address[] gauges, uint256[] weights);
    event ExpiredLocksProcessed(bool relocked);
    event ConvexContractsSet(address cvxLocker, address voteProxy, address cvxRewardPool, address cvxCrv);
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
        address cvx_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (vault_ == address(0) || usdc_ == address(0) || cvx_ == address(0)) {
            revert IErrors.ZeroAddress();
        }

        vault = vault_;
        usdc = IERC20(usdc_);
        cvx = IERC20(cvx_);
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

    function setConvexContracts(
        address cvxLocker_,
        address voteProxy_,
        address cvxRewardPool_,
        address cvxCrv_
    ) external onlyGovernor {
        if (cvxLocker_ != address(0)) cvxLocker = ICvxLocker(cvxLocker_);
        if (voteProxy_ != address(0)) voteProxy = ICvxVoteProxy(voteProxy_);
        cvxRewardPool = cvxRewardPool_;
        cvxCrv = cvxCrv_;
        emit ConvexContractsSet(cvxLocker_, voteProxy_, cvxRewardPool_, cvxCrv_);
    }

    // -----------------------------------------------------------------------
    // IStrategyAdapter Implementation
    // -----------------------------------------------------------------------

    /**
     * @notice Vault transfers USDC, adapter swaps to CVX and locks to vlCVX
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

        // NOTE: In production, implement USDC→CVX swap and lock to vlCVX:
        /*
        // 1. Swap USDC → CVX using swapRouter with oracle validation
        usdc.safeApprove(swapRouter, 0);
        usdc.safeApprove(swapRouter, usdcAmount);
        uint256 cvxOut = ISwapRouter(swapRouter).exactInputSingle(...);

        // 2. Lock CVX → vlCVX
        cvx.safeApprove(cvxLocker, 0);
        cvx.safeApprove(cvxLocker, cvxOut);

        // Lock for 16 weeks (Convex standard)
        ICvxLocker(cvxLocker).lock(address(this), cvxOut, 0);
        lockEpoch = ICvxLocker(cvxLocker).epochCount();

        // Calculate next unlock (16 weeks from now, aligned to epoch)
        nextUnlockTimestamp = block.timestamp + 16 weeks;

        emit CvxLocked(cvxOut, lockEpoch);
        */

        return usdcAmount; // Deployed notionally equals USDC contributed
    }

    /**
     * @notice Harvest vlCVX rewards (cvxCRV, bribes) and swap to USDC
     */
    function harvest() external override nonReentrant returns (uint256 estimatedUsdcOut) {
        if (msg.sender != harvester && msg.sender != keeper) revert IErrors.Unauthorized();

        // NOTE: In production, implement:
        // 1. Claim cvxCRV rewards from CvxLockerV2
        // 2. Claim platform fees (3CRV or other)
        // 3. Claim any bribes from Votium or Convex bribe platform
        // 4. Swap all reward tokens → USDC via configured swapper
        // 5. Transfer USDC to Harvester

        /*
        if (cvxLocker != address(0)) {
            // Get all pending rewards
            address[] memory rewardTokens = ICvxLocker(cvxLocker).rewardTokens();
            uint256[] memory amounts = new uint256[](rewardTokens.length);

            // Claim all rewards
            ICvxLocker(cvxLocker).getReward(address(this), false);

            // Record amounts claimed
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                amounts[i] = IERC20(rewardTokens[i]).balanceOf(address(this));
            }

            emit RewardsClaimed(amounts, rewardTokens);

            // Swap rewards to USDC (via Harvester's swapper)
            // Transfer to Harvester
        }
        */

        return 0; // Placeholder
    }

    /**
     * @notice TVL in USDC terms = locked CVX value (via oracle)
     */
    function tvl() external view override returns (uint256) {
        // NOTE: In production, query vlCVX balance and convert via oracle
        /*
        if (cvxLocker != address(0)) {
            uint256 lockedCvx = ICvxLocker(cvxLocker).balanceOf(address(this));
            // Convert to USDC via oracle/guard
            return guard.quoteMinOut(address(cvx), address(usdc), lockedCvx);
        }
        */

        return 0; // Placeholder - implement oracle conversion
    }

    /**
     * @notice Emergency unwind: process unlocked CVX, swap to USDC, return to vault
     */
    function emergencyWithdraw() external override nonReentrant returns (uint256 recoveredUsdc) {
        if (msg.sender != governor && msg.sender != guardian) revert IErrors.Unauthorized();

        // NOTE: vlCVX locks for 16 weeks and cannot be unlocked early
        // Emergency withdrawal can only recover:
        // 1. CVX that has already unlocked
        // 2. Pending rewards
        // 3. Idle USDC

        /*
        if (cvxLocker != address(0)) {
            // Process expired locks (if any)
            ICvxLocker(cvxLocker).processExpiredLocks(false);

            // Withdraw unlocked CVX
            uint256 cvxBal = cvx.balanceOf(address(this));
            if (cvxBal > 0) {
                // Swap CVX → USDC
                cvx.safeApprove(swapRouter, 0);
                cvx.safeApprove(swapRouter, cvxBal);
                // Execute swap...
            }
        }
        */

        recoveredUsdc = usdc.balanceOf(address(this));
        if (recoveredUsdc > 0) {
            usdc.safeTransfer(vault, recoveredUsdc);
        }
    }

    function name() external pure override returns (string memory) {
        return "Convex vlCVX";
    }

    function underlyingToken() external view override returns (address) {
        return address(cvx);
    }

    // -----------------------------------------------------------------------
    // ILockingAdapter Implementation
    // -----------------------------------------------------------------------

    function lockedUntil() external view override returns (uint256) {
        return nextUnlockTimestamp;
    }

    // -----------------------------------------------------------------------
    // IVotingAdapter Implementation
    // -----------------------------------------------------------------------

    /**
     * @notice Vote on Convex/Curve gauges with vlCVX voting power
     * @dev Convex uses a vote proxy to vote on Curve gauges
     * @param gauges Array of gauge addresses to vote for
     * @param weights Array of weights to allocate to each gauge
     */
    function vote(address[] calldata gauges, uint256[] calldata weights) external override {
        if (msg.sender != voterRouter && msg.sender != keeper) revert IErrors.Unauthorized();
        if (gauges.length != weights.length) revert IErrors.InvalidAmount();

        // Use vote proxy if available (for on-chain voting)
        if (address(voteProxy) != address(0)) {
            voteProxy.voteMultipleGauges(gauges, weights);
        }
        // If no vote proxy, voting may be done through Snapshot (off-chain)
        // In that case, this function just emits an event for off-chain indexing

        emit VoteCast(gauges, weights);
    }

    // -----------------------------------------------------------------------
    // vlCVX Operations
    // -----------------------------------------------------------------------

    /**
     * @notice Lock CVX tokens to receive vlCVX
     * @param amount Amount of CVX to lock
     * @param spendRatio Boost spending ratio (0 = no boost, higher = more boost)
     */
    function lockCvx(uint256 amount, uint256 spendRatio) external onlyKeeper whenNotPaused nonReentrant {
        if (amount == 0) revert IErrors.InvalidAmount();
        if (address(cvxLocker) == address(0)) revert IErrors.ZeroAddress();

        uint256 cvxBal = cvx.balanceOf(address(this));
        if (amount > cvxBal) amount = cvxBal;

        cvx.safeApprove(address(cvxLocker), 0);
        cvx.safeApprove(address(cvxLocker), amount);

        cvxLocker.lock(address(this), amount, spendRatio);
        lockEpoch = cvxLocker.epochCount();
        nextUnlockTimestamp = block.timestamp + 16 weeks;

        emit CvxLocked(amount, lockEpoch);
    }

    /**
     * @notice Process expired locks and optionally relock
     * @param relock If true, relock the expired CVX for continued voting power
     */
    function processExpiredLocks(bool relock) external onlyKeeper nonReentrant {
        if (address(cvxLocker) == address(0)) revert IErrors.ZeroAddress();

        cvxLocker.processExpiredLocks(relock);

        if (relock) {
            nextUnlockTimestamp = block.timestamp + 16 weeks;
        }

        emit ExpiredLocksProcessed(relock);
    }

    /**
     * @notice Relock expired CVX for continued voting power
     * @dev Convenience function that calls processExpiredLocks(true)
     */
    function relockExpiredCvx() external onlyKeeper nonReentrant whenNotPaused {
        if (address(cvxLocker) == address(0)) revert IErrors.ZeroAddress();

        cvxLocker.processExpiredLocks(true); // relock = true
        nextUnlockTimestamp = block.timestamp + 16 weeks;

        emit ExpiredLocksProcessed(true);
    }

    /**
     * @notice Claim all vlCVX rewards (cvxCRV, bribes, etc.)
     * @return tokens Array of reward token addresses
     * @return amounts Array of amounts claimed
     */
    function claimAllRewards() external onlyKeeper whenNotPaused nonReentrant returns (address[] memory tokens, uint256[] memory amounts) {
        if (address(cvxLocker) == address(0)) revert IErrors.ZeroAddress();

        // Get claimable rewards
        ICvxLocker.EarnedData[] memory claimable = cvxLocker.claimableRewards(address(this));

        // Prepare return arrays
        tokens = new address[](claimable.length);
        amounts = new uint256[](claimable.length);

        for (uint256 i = 0; i < claimable.length; i++) {
            tokens[i] = claimable[i].token;
            amounts[i] = claimable[i].amount;
        }

        // Claim all rewards
        cvxLocker.getReward(address(this), false); // stake = false

        emit RewardsClaimed(amounts, tokens);
    }

    /**
     * @notice Withdraw expired locks without relocking
     */
    function withdrawExpiredLocks() external onlyKeeper nonReentrant {
        if (address(cvxLocker) == address(0)) revert IErrors.ZeroAddress();

        cvxLocker.withdrawExpiredLocksTo(address(this));
    }

    /**
     * @notice Get locked balance information
     * @return total Total locked balance (including boost)
     * @return unlockable Amount that can be unlocked
     * @return locked Amount currently locked
     */
    function getLockedBalances() external view returns (uint256 total, uint256 unlockable, uint256 locked) {
        if (address(cvxLocker) == address(0)) return (0, 0, 0);

        (total, unlockable, locked,) = cvxLocker.lockedBalances(address(this));
    }

    /**
     * @notice Get voting power balance
     * @return Total vlCVX balance (including boost)
     */
    function getVotingPower() external view returns (uint256) {
        if (address(cvxLocker) == address(0)) return 0;
        return cvxLocker.balanceOf(address(this));
    }

    /**
     * @notice Get claimable rewards
     * @return claimable Array of claimable reward data
     */
    function getClaimableRewards() external view returns (ICvxLocker.EarnedData[] memory claimable) {
        if (address(cvxLocker) == address(0)) {
            return new ICvxLocker.EarnedData[](0);
        }
        return cvxLocker.claimableRewards(address(this));
    }

    // -----------------------------------------------------------------------
    // Emergency Recovery
    // -----------------------------------------------------------------------

    function rescueToken(address token, address to, uint256 amount) external onlyGovernor {
        if (token == address(0) || to == address(0)) revert IErrors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }
}
