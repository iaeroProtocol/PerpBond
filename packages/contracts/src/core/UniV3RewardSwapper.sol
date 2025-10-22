// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./AccessRoles.sol";
import "./ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";

/// @notice Minimal Uniswap v3 router interface (exactInput / exactInputSingle).
interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96; // set 0 for no limit
    }

    struct ExactInputParams {
        bytes   path;       // tokenIn, fee, tokenMid, fee, tokenOut ...
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/**
 * @title UniV3RewardSwapper
 * @notice Pluggable reward swapper for Harvester: swaps arbitrary reward tokens to USDC via Uniswap v3.
 * @dev    - Restricted so only the authorized caller (Harvester) can execute swaps using its allowances.
 *         - Supports direct pools (exactInputSingle) or multi-hop paths (exactInput).
 *         - Uses SafeTransferLib for robust approvals and transfers.
 */
contract UniV3RewardSwapper is AccessRoles, ErrorsEvents, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    // -----------------------------------------------------------------------
    // Immutable config
    // -----------------------------------------------------------------------
    ISwapRouterV3 public immutable router;
    IERC20        public immutable usdc;

    // -----------------------------------------------------------------------
    // Mutable config
    // -----------------------------------------------------------------------
    address public authorizedCaller;                 // should be Harvester
    mapping(address => uint24) public feeFor;        // token => pool fee for direct pool
    mapping(address => bytes)  public pathFor;       // token => encoded multi-hop path to USDC

    /// @notice SECURITY FIX: Deadline offset in seconds to prevent MEV/sandwiching (default 30 min)
    uint256 public deadlineOffset = 1800; // 30 minutes

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event AuthorizedCallerSet(address indexed oldCaller, address indexed newCaller);
    event FeeSet(address indexed token, uint24 fee);
    event PathSet(address indexed token, bytes path);
    event Swapped(address indexed tokenIn, uint256 amountIn, uint256 usdcOut, address indexed recipient);

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------
    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address router_,
        address usdc_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (router_ == address(0) || usdc_ == address(0)) revert IErrors.ZeroAddress();
        router = ISwapRouterV3(router_);
        usdc   = IERC20(usdc_);
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    /// @notice Set the only address allowed to call swapToUSDC (expected: Harvester).
    function setAuthorizedCaller(address caller) external onlyGovernor {
        address old = authorizedCaller;
        authorizedCaller = caller;
        emit AuthorizedCallerSet(old, caller);
    }

    /// @notice Configure direct-pool fee tier for a reward token (used when no path is set).
    function setFee(address token, uint24 fee) external onlyGovernor {
        if (token == address(0)) revert IErrors.ZeroAddress();
        feeFor[token] = fee; // 500, 3000, or 10000 typically
        emit FeeSet(token, fee);
    }

    /// @notice Configure a multi-hop path for a reward token to USDC (overrides feeFor if set).
    /// @dev    Encode as: abi.encodePacked(tokenIn, fee1, midToken, fee2, ..., usdc)
    function setPath(address token, bytes calldata path) external onlyGovernor {
        if (token == address(0)) revert IErrors.ZeroAddress();
        // Optional sanity: require last 20 bytes of path == USDC, but we keep it flexible here.
        pathFor[token] = path;
        emit PathSet(token, path);
    }

    /// @notice Set the deadline offset for swap transactions (SECURITY: prevents MEV)
    /// @param offset Seconds from block.timestamp (e.g., 1800 = 30 min, max 3600 = 1 hour)
    function setDeadlineOffset(uint256 offset) external onlyGovernor {
        if (offset == 0 || offset > 3600) revert IErrors.InvalidAmount();
        deadlineOffset = offset;
    }

    /// @notice Rescue any token accidentally stuck in the swapper.
    function rescueToken(address token, address to, uint256 amount) external onlyGovernor {
        if (token == address(0) || to == address(0)) revert IErrors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // -----------------------------------------------------------------------
    // Swapping (authorized by Harvester)
    // -----------------------------------------------------------------------

    /// @notice Swap `amountIn` of `token` (from caller) to USDC and send to `recipient`.
    /// @dev    Caller must be `authorizedCaller` (Harvester), which should have set allowance for this swapper.
    ///         - Pulls `token` from caller with transferFrom.
    ///         - Executes Uniswap v3 swap with either configured path or single pool.
    ///         - Sends USDC directly to `recipient`.
    function swapToUSDC(
        address token,
        uint256 amountIn,
        uint256 minUsdcOut,
        address recipient
    ) external nonReentrant returns (uint256 usdcOut) {
        if (msg.sender != authorizedCaller) revert IErrors.Unauthorized();
        if (token == address(0) || recipient == address(0)) revert IErrors.ZeroAddress();
        if (amountIn == 0) revert IErrors.InvalidAmount();

        // Pull reward tokens from the caller (Harvester).
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve router for this swap amount.
        IERC20(token).safeApprove(address(router), 0);
        IERC20(token).safeApprove(address(router), amountIn);

        // SECURITY FIX: Use deadline offset instead of block.timestamp for MEV protection
        uint256 deadline = block.timestamp + deadlineOffset;

        bytes memory path = pathFor[token];
        if (path.length > 0) {
            // Multi-hop: token -> ... -> USDC
            ISwapRouterV3.ExactInputParams memory p = ISwapRouterV3.ExactInputParams({
                path: path,
                recipient: recipient,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minUsdcOut
            });
            usdcOut = router.exactInput(p);
        } else {
            // Single pool: token -> USDC using configured fee tier
            uint24 fee = feeFor[token];
            if (fee == 0) revert IErrors.InvalidAmount(); // no config
            ISwapRouterV3.ExactInputSingleParams memory p = ISwapRouterV3.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(usdc),
                fee: fee,
                recipient: recipient,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minUsdcOut,
                sqrtPriceLimitX96: 0
            });
            usdcOut = router.exactInputSingle(p);
        }

        emit Swapped(token, amountIn, usdcOut, recipient);
    }
}
