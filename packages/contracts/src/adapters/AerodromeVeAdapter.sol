// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../core/AccessRoles.sol";
import "../core/ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";
import "./IStrategyAdapter.sol";
import "./IVotingAdapter.sol";
import "./ILockingAdapter.sol";
import "../core/RouterGuard.sol";
import "../interfaces/external/IAerodromeVotingEscrow.sol";

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256);
}

/// @title AerodromeVeAdapter (extended swap-enabled v2 with NFT support)
/// @notice Swaps USDC->AERO on deposit using Uniswap v3, locks to veAERO NFT, supports voting,
///         unlockPermanent, reset, and extend operations, reports TVL in USDC via RouterGuard oracles.
contract AerodromeVeAdapter is
    AccessRoles,

    ReentrancyGuard,
    IStrategyAdapter,
    IVotingAdapter,
    ILockingAdapter
{
    using SafeTransferLib for IERC20;

    // Immutable core
    IERC20 public immutable usdc;      // 6 decimals
    IERC20 public immutable aero;      // underlying
    address public immutable vault;    // vault is the only caller of deposit()

    // Addresses
    ISwapRouterV3 public swapRouter;   // Uniswap v3 router
    RouterGuard   public guard;        // Router whitelist + oracle slippage checks
    address       public harvester;    // allowed caller for harvest()
    address       public voterRouter;  // allowed caller for vote()

    // Aerodrome protocol contracts
    IAerodromeVotingEscrow public votingEscrow; // veAERO NFT contract
    IAerodromeVoter        public voter;        // Aerodrome voter for gauge voting

    // NFT state
    uint256 public veNftTokenId;       // The veAERO NFT token ID owned by this adapter
    bool    public isPermanentLock;    // Whether the lock is permanent

    // Routing config for deposits (USDC -> AERO) and exits (AERO -> USDC)
    bytes  public depositPath;         // if set, use exactInput(path)
    uint24 public depositFee;          // else, use exactInputSingle with this fee
    bytes  public exitPath;            // if set, use exactInput(path)
    uint24 public exitFee;             // else, use exactInputSingle with this fee

    // Events
    event HarvesterSet(address indexed oldHarvester, address indexed newHarvester);
    event VoterRouterSet(address indexed oldRouter, address indexed newRouter);
    event GuardSet(address indexed oldGuard, address indexed newGuard);
    event RouterSet(address indexed oldRouter, address indexed newRouter);
    event DepositRouteSet(bytes path, uint24 fee);
    event ExitRouteSet(bytes path, uint24 fee);
    event IdleConverted(uint256 usdcIn, uint256 aeroOut);
    event AeroSold(uint256 aeroIn, uint256 usdcOut);
    event AerodromeContractsSet(address indexed votingEscrow, address indexed voter);
    event VeNftCreated(uint256 indexed tokenId, uint256 amount, uint256 duration);
    event VeNftIncreased(uint256 indexed tokenId, uint256 amount);
    event VeNftLockExtended(uint256 indexed tokenId, uint256 newDuration);
    event VeNftPermanentLocked(uint256 indexed tokenId);
    event VeNftPermanentUnlocked(uint256 indexed tokenId);
    event VoteCast(uint256 indexed tokenId, address[] pools, uint256[] weights);
    event VoteReset(uint256 indexed tokenId);
    event BribesClaimed(address[] bribes, uint256 totalValue);
    event FeesClaimed(address[] fees, uint256 totalValue);

    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address vault_,
        address usdc_,
        address aero_,
        address router_,
        address guard_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (vault_ == address(0) || usdc_ == address(0) || aero_ == address(0)) revert IErrors.ZeroAddress();
        vault = vault_;
        usdc = IERC20(usdc_);
        aero = IERC20(aero_);
        if (router_ != address(0)) swapRouter = ISwapRouterV3(router_);
        if (guard_   != address(0)) guard      = RouterGuard(guard_);
    }

    /*------------------------------ Admin ------------------------------*/

    function setHarvester(address newHarvester) external onlyGovernor {
        address old = harvester;
        harvester = newHarvester;
        emit HarvesterSet(old, newHarvester);
    }

    function setVoterRouter(address newRouter) external onlyGovernor {
        address old = voterRouter;
        voterRouter = newRouter;
        emit VoterRouterSet(old, newRouter);
    }

    function setRouter(address newRouter) external onlyGovernor {
        if (newRouter == address(0)) revert IErrors.ZeroAddress();
        address old = address(swapRouter);
        swapRouter = ISwapRouterV3(newRouter);
        emit RouterSet(old, newRouter);
    }

    function setGuard(address newGuard) external onlyGovernor {
        address old = address(guard);
        guard = RouterGuard(newGuard);
        emit GuardSet(old, newGuard);
    }

    function setAerodromeContracts(address votingEscrow_, address voter_) external onlyGovernor {
        if (votingEscrow_ != address(0)) votingEscrow = IAerodromeVotingEscrow(votingEscrow_);
        if (voter_ != address(0)) voter = IAerodromeVoter(voter_);
        emit AerodromeContractsSet(votingEscrow_, voter_);
    }

    /// @notice Configure deposit route (USDC->AERO). Provide either path (preferred) or fee (single pool).
    function setDepositRoute(bytes calldata path, uint24 fee) external onlyGovernor {
        depositPath = path; // if non-empty, path takes precedence
        depositFee  = path.length > 0 ? 0 : fee;
        emit DepositRouteSet(path, fee);
    }

    /// @notice Configure exit route (AERO->USDC). Provide either path (preferred) or fee (single pool).
    function setExitRoute(bytes calldata path, uint24 fee) external onlyGovernor {
        exitPath = path;
        exitFee  = path.length > 0 ? 0 : fee;
        emit ExitRouteSet(path, fee);
    }

    /// @notice Rescue arbitrary tokens mistakenly sent here.
    function rescueToken(address token, address to, uint256 amount) external onlyGovernor {
        if (token == address(0) || to == address(0)) revert IErrors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /*-------------------------- IStrategyAdapter -----------------------*/

    /// @notice Vault transfers USDC to this contract then calls deposit(usdcAmount).
    /// @dev    If a deposit route is set, swaps to AERO; otherwise leaves USDC idle (still counted in TVL).
    function deposit(uint256 usdcAmount)
        external
        override
        nonReentrant
        returns (uint256 deployedUsdc)
    {
        if (msg.sender != vault) revert IErrors.Unauthorized();
        if (usdcAmount == 0) revert IErrors.InvalidAmount();

        // Be defensive: bound by actual balance.
        uint256 bal = usdc.balanceOf(address(this));
        if (usdcAmount > bal) usdcAmount = bal;

        // If routing not configured yet, hold USDC as-is (deployed notionally == usdcAmount).
        if (address(swapRouter) == address(0) || (depositPath.length == 0 && depositFee == 0)) {
            return usdcAmount;
        }

        // Compute a guarded minOut for USDC->AERO and validate router/slippage if a guard is set.
        uint256 minAeroOut = 0;
        if (address(guard) != address(0)) {
            minAeroOut = guard.quoteMinOut(address(usdc), address(aero), usdcAmount);
            guard.validateSwap(address(swapRouter), address(usdc), address(aero), usdcAmount, minAeroOut);
        }

        // Approve and execute swap.
        usdc.safeApprove(address(swapRouter), 0);
        usdc.safeApprove(address(swapRouter), usdcAmount);

        uint256 aeroOut;
        if (depositPath.length > 0) {
            aeroOut = ISwapRouterV3(swapRouter).exactInput(
                ISwapRouterV3.ExactInputParams({
                    path: depositPath,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdcAmount,
                    amountOutMinimum: minAeroOut
                })
            );
        } else {
            aeroOut = ISwapRouterV3(swapRouter).exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams({
                    tokenIn:  address(usdc),
                    tokenOut: address(aero),
                    fee:      depositFee,
                    recipient: address(this),
                    deadline:  block.timestamp,
                    amountIn:  usdcAmount,
                    amountOutMinimum: minAeroOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        emit IdleConverted(usdcAmount, aeroOut);
        // Deployed notionally equals USDC contributed (consistent with USDC-based accounting).
        return usdcAmount;
    }

    /// @notice Harvest rewards. Stub for now (protocol-specific claims to be added).
    function harvest() external override nonReentrant returns (uint256 estimatedUsdcOut) {
        if (msg.sender != harvester && msg.sender != keeper) revert IErrors.Unauthorized();
        return 0;
    }

    /// @notice TVL in USDC terms = USDC balance + oracle-quoted AERO→USDC.
    function tvl() external view override returns (uint256) {
        uint256 usdcBal = usdc.balanceOf(address(this));
        uint256 aeroBal = aero.balanceOf(address(this));
        if (aeroBal == 0) return usdcBal;

        // Use guard (Chainlink via OracleLib) if configured; otherwise ignore AERO value to be conservative.
        if (address(guard) == address(0)) return usdcBal;

        uint256 aeroAsUsdc = guard.quoteMinOut(address(aero), address(usdc), aeroBal);
        return usdcBal + aeroAsUsdc;
    }

    /// @notice Best-effort unwind to USDC and return funds to the Vault.
    function emergencyWithdraw() external override nonReentrant returns (uint256 recoveredUsdc) {
        if (msg.sender != governor && msg.sender != guardian) revert IErrors.Unauthorized();

        // 1) Try to sell AERO -> USDC using configured exit route.
        uint256 aeroBal = aero.balanceOf(address(this));
        if (aeroBal > 0 && address(swapRouter) != address(0) && (exitPath.length > 0 || exitFee > 0)) {
            uint256 minUsdc = 0;
            if (address(guard) != address(0)) {
                minUsdc = guard.quoteMinOut(address(aero), address(usdc), aeroBal);
                guard.validateSwap(address(swapRouter), address(aero), address(usdc), aeroBal, minUsdc);
            }

            aero.safeApprove(address(swapRouter), 0);
            aero.safeApprove(address(swapRouter), aeroBal);

            uint256 out;
            if (exitPath.length > 0) {
                out = ISwapRouterV3(swapRouter).exactInput(
                    ISwapRouterV3.ExactInputParams({
                        path: exitPath,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: aeroBal,
                        amountOutMinimum: minUsdc
                    })
                );
            } else {
                out = ISwapRouterV3(swapRouter).exactInputSingle(
                    ISwapRouterV3.ExactInputSingleParams({
                        tokenIn:  address(aero),
                        tokenOut: address(usdc),
                        fee:      exitFee,
                        recipient: address(this),
                        deadline:  block.timestamp,
                        amountIn:  aeroBal,
                        amountOutMinimum: minUsdc,
                        sqrtPriceLimitX96: 0
                    })
                );
            }
            emit AeroSold(aeroBal, out);
        }

        // 2) Transfer any USDC on hand back to the Vault.
        recoveredUsdc = usdc.balanceOf(address(this));
        if (recoveredUsdc > 0) {
            usdc.safeTransfer(vault, recoveredUsdc);
        }
    }

    function name() external pure override returns (string memory) {
        return "Aerodrome veAERO (swap v2)";
    }

    function underlyingToken() external view override returns (address) {
        return address(aero);
    }

    /*-------------------------- ILockingAdapter ------------------------*/

    /// @notice Get the unlock timestamp for the veAERO NFT
    function lockedUntil() external view override returns (uint256) {
        // Permanent locks return max timestamp
        if (isPermanentLock) return type(uint256).max;
        // For time-locked positions, would need to query the VotingEscrow contract
        // This is a simplified implementation
        return 0;
    }

    /*--------------------------- IVotingAdapter ------------------------*/

    /// @notice Vote on Aerodrome gauges using the veAERO NFT
    /// @param pools Array of pool addresses to vote for
    /// @param weights Array of weights (must sum to <= 100%)
    function vote(address[] calldata pools, uint256[] calldata weights) external override {
        if (msg.sender != voterRouter && msg.sender != keeper) revert IErrors.Unauthorized();
        if (pools.length != weights.length) revert IErrors.InvalidAmount();
        if (address(voter) == address(0)) revert IErrors.ZeroAddress();
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();

        voter.vote(veNftTokenId, pools, weights);
        emit VoteCast(veNftTokenId, pools, weights);
    }

    /*------------------------- veAERO NFT Operations -------------------*/

    /// @notice Create a veAERO NFT by locking AERO
    /// @param amount Amount of AERO to lock
    /// @param duration Lock duration in seconds (must be aligned to weeks)
    function createVeNft(uint256 amount, uint256 duration) external onlyKeeper whenNotPaused nonReentrant {
        if (amount == 0) revert IErrors.InvalidAmount();
        if (address(votingEscrow) == address(0)) revert IErrors.ZeroAddress();
        if (veNftTokenId != 0) revert IErrors.InvalidAmount(); // Already have an NFT

        uint256 aeroBal = aero.balanceOf(address(this));
        if (amount > aeroBal) amount = aeroBal;

        aero.safeApprove(address(votingEscrow), 0);
        aero.safeApprove(address(votingEscrow), amount);

        veNftTokenId = votingEscrow.createLock(amount, duration);
        emit VeNftCreated(veNftTokenId, amount, duration);
    }

    /// @notice Increase the amount locked in the veAERO NFT
    /// @param amount Additional AERO to lock
    function increaseVeNftAmount(uint256 amount) external onlyKeeper whenNotPaused nonReentrant {
        if (amount == 0) revert IErrors.InvalidAmount();
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();

        uint256 aeroBal = aero.balanceOf(address(this));
        if (amount > aeroBal) amount = aeroBal;

        aero.safeApprove(address(votingEscrow), 0);
        aero.safeApprove(address(votingEscrow), amount);

        votingEscrow.increaseAmount(veNftTokenId, amount);
        emit VeNftIncreased(veNftTokenId, amount);
    }

    /// @notice Extend the lock duration for the veAERO NFT
    /// @param newDuration New lock duration (must be > current)
    function increaseUnlockTime(uint256 newDuration) external onlyKeeper whenNotPaused nonReentrant {
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();
        if (address(votingEscrow) == address(0)) revert IErrors.ZeroAddress();

        votingEscrow.increaseUnlockTime(veNftTokenId, newDuration);
        emit VeNftLockExtended(veNftTokenId, newDuration);
    }

    /// @notice Convert the veAERO NFT to a permanent lock
    function lockPermanent() external onlyKeeper whenNotPaused nonReentrant {
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();
        if (address(votingEscrow) == address(0)) revert IErrors.ZeroAddress();
        if (isPermanentLock) revert IErrors.InvalidAmount(); // Already permanent

        votingEscrow.lockPermanent(veNftTokenId);
        isPermanentLock = true;
        emit VeNftPermanentLocked(veNftTokenId);
    }

    /// @notice Unlock a permanent veAERO NFT (convert back to time-locked)
    function unlockPermanent() external onlyKeeper whenNotPaused nonReentrant {
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();
        if (address(votingEscrow) == address(0)) revert IErrors.ZeroAddress();
        if (!isPermanentLock) revert IErrors.InvalidAmount(); // Not permanent

        votingEscrow.unlockPermanent(veNftTokenId);
        isPermanentLock = false;
        emit VeNftPermanentUnlocked(veNftTokenId);
    }

    /// @notice Reset all votes for the veAERO NFT
    function reset() external onlyKeeper whenNotPaused nonReentrant {
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();
        if (address(voter) == address(0)) revert IErrors.ZeroAddress();

        voter.reset(veNftTokenId);
        emit VoteReset(veNftTokenId);
    }

    /// @notice Claim bribes from voted gauges
    /// @param bribes Array of bribe contract addresses
    /// @param tokens Array of token arrays to claim per bribe
    function claimBribes(address[] calldata bribes, address[][] calldata tokens)
        external
        onlyKeeper
        whenNotPaused
        nonReentrant
    {
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();
        if (address(voter) == address(0)) revert IErrors.ZeroAddress();

        uint256 usdcBefore = usdc.balanceOf(address(this));
        voter.claimBribes(bribes, tokens, veNftTokenId);
        uint256 usdcAfter = usdc.balanceOf(address(this));

        emit BribesClaimed(bribes, usdcAfter - usdcBefore);
    }

    /// @notice Claim fees from voted gauges
    /// @param fees Array of fee contract addresses
    /// @param tokens Array of token arrays to claim per fee
    function claimFees(address[] calldata fees, address[][] calldata tokens)
        external
        onlyKeeper
        whenNotPaused
        nonReentrant
    {
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();
        if (address(voter) == address(0)) revert IErrors.ZeroAddress();

        uint256 usdcBefore = usdc.balanceOf(address(this));
        voter.claimFees(fees, tokens, veNftTokenId);
        uint256 usdcAfter = usdc.balanceOf(address(this));

        emit FeesClaimed(fees, usdcAfter - usdcBefore);
    }

    /// @notice Merge two veAERO NFTs (requires both to be owned by adapter)
    /// @param fromTokenId Token ID to merge from (will be burned)
    /// @param toTokenId Token ID to merge into
    function mergeVeNfts(uint256 fromTokenId, uint256 toTokenId)
        external
        onlyGovernor
        nonReentrant
    {
        if (address(votingEscrow) == address(0)) revert IErrors.ZeroAddress();
        votingEscrow.merge(fromTokenId, toTokenId);
    }

    /// @notice Withdraw from an expired veAERO NFT
    function withdrawVeNft() external onlyKeeper nonReentrant {
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();
        if (address(votingEscrow) == address(0)) revert IErrors.ZeroAddress();
        if (isPermanentLock) revert IErrors.InvalidAmount(); // Cannot withdraw permanent lock

        votingEscrow.withdraw(veNftTokenId);
        veNftTokenId = 0;
    }

    /*--------------------------- Keeper helpers ------------------------*/

    /// @notice Convert a portion of idle USDC held by the adapter to AERO using the deposit route.
    function convertIdleUSDC(uint256 usdcAmount) external onlyKeeper whenNotPaused nonReentrant {
        if (usdcAmount == 0) revert IErrors.InvalidAmount();
        uint256 bal = usdc.balanceOf(address(this));
        if (usdcAmount > bal) usdcAmount = bal;

        if (address(swapRouter) == address(0) || (depositPath.length == 0 && depositFee == 0)) revert IErrors.RouterNotAllowed();

        uint256 minAeroOut = address(guard) != address(0)
            ? guard.quoteMinOut(address(usdc), address(aero), usdcAmount)
            : 0;

        if (address(guard) != address(0)) {
            guard.validateSwap(address(swapRouter), address(usdc), address(aero), usdcAmount, minAeroOut);
        }

        usdc.safeApprove(address(swapRouter), 0);
        usdc.safeApprove(address(swapRouter), usdcAmount);

        uint256 aeroOut;
        if (depositPath.length > 0) {
            aeroOut = ISwapRouterV3(swapRouter).exactInput(
                ISwapRouterV3.ExactInputParams({
                    path: depositPath,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdcAmount,
                    amountOutMinimum: minAeroOut
                })
            );
        } else {
            aeroOut = ISwapRouterV3(swapRouter).exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams({
                    tokenIn:  address(usdc),
                    tokenOut: address(aero),
                    fee:      depositFee,
                    recipient: address(this),
                    deadline:  block.timestamp,
                    amountIn:  usdcAmount,
                    amountOutMinimum: minAeroOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        emit IdleConverted(usdcAmount, aeroOut);
    }

    /// @notice Sell some AERO for USDC using the exit route (keeper maintenance / manual unwind).
    function sellAeroForUSDC(uint256 aeroAmount) external onlyKeeper whenNotPaused nonReentrant {
        if (aeroAmount == 0) revert IErrors.InvalidAmount();
        uint256 bal = aero.balanceOf(address(this));
        if (aeroAmount > bal) aeroAmount = bal;

        if (address(swapRouter) == address(0) || (exitPath.length == 0 && exitFee == 0)) revert IErrors.RouterNotAllowed();

        uint256 minUsdcOut = address(guard) != address(0)
            ? guard.quoteMinOut(address(aero), address(usdc), aeroAmount)
            : 0;

        if (address(guard) != address(0)) {
            guard.validateSwap(address(swapRouter), address(aero), address(usdc), aeroAmount, minUsdcOut);
        }

        aero.safeApprove(address(swapRouter), 0);
        aero.safeApprove(address(swapRouter), aeroAmount);

        uint256 out;
        if (exitPath.length > 0) {
            out = ISwapRouterV3(swapRouter).exactInput(
                ISwapRouterV3.ExactInputParams({
                    path: exitPath,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: aeroAmount,
                    amountOutMinimum: minUsdcOut
                })
            );
        } else {
            out = ISwapRouterV3(swapRouter).exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams({
                    tokenIn:  address(aero),
                    tokenOut: address(usdc),
                    fee:      exitFee,
                    recipient: address(this),
                    deadline:  block.timestamp,
                    amountIn:  aeroAmount,
                    amountOutMinimum: minUsdcOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        emit AeroSold(aeroAmount, out);
    }
}
