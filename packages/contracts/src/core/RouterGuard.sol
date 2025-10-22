// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./AccessRoles.sol";
import "./ErrorsEvents.sol";
import "../libs/OracleLib.sol";

/**
 * @title RouterGuard
 * @notice Whitelists swap routers and enforces per-pair max slippage using oracle quotes.
 * @dev    Configure Chainlink feeds for each token (token->USD) and a staleness window.
 *         Consumers (e.g., Harvester) should call validateSwap() before swapping.
 */
contract RouterGuard is AccessRoles {
    uint16 public constant BPS_DENOMINATOR = 10_000;

    // router => allowed
    mapping(address => bool) public allowedRouters;

    // tokenIn => tokenOut => max slippage in bps (e.g., 50 = 0.5%)
    mapping(address => mapping(address => uint16)) public maxSlippageBps;

    // Token oracle configuration (token -> Chainlink feed + staleness + token decimals)
    mapping(address => OracleLib.ChainlinkFeed) public feedOf;

    // --- Events ---
    event RouterAllowed(address indexed router, bool allowed);
    event MaxSlippageSet(address indexed tokenIn, address indexed tokenOut, uint16 bps);
    event FeedSet(address indexed token, address indexed aggregator, uint48 staleAfter, uint8 tokenDecimals);

    // --- Constructor ---
    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {}

    // --- Admin: routers, slippage, feeds ---

    function setRouterAllowed(address router, bool allowed) external onlyGovernor {
        if (router == address(0)) revert IErrors.ZeroAddress();
        allowedRouters[router] = allowed;
        emit RouterAllowed(router, allowed);
    }

    function setMaxSlippageBps(address tokenIn, address tokenOut, uint16 bps) external onlyGovernor {
        if (tokenIn == address(0) || tokenOut == address(0)) revert IErrors.ZeroAddress();
        if (bps > BPS_DENOMINATOR) revert IErrors.InvalidAmount();
        maxSlippageBps[tokenIn][tokenOut] = bps;
        emit MaxSlippageSet(tokenIn, tokenOut, bps);
    }

    /// @param token         ERC20 token address whose USD price feed is configured
    /// @param aggregator    Chainlink AggregatorV3 (token/USD or USD/token inverted handled in OracleLib if needed)
    /// @param staleAfter    Max allowed staleness in seconds (e.g., 1 hour = 3600)
    /// @param tokenDecimals Native decimals for `token` (e.g., USDC=6, WETH=18)
    function setFeed(address token, address aggregator, uint48 staleAfter, uint8 tokenDecimals) external onlyGovernor {
        if (token == address(0) || aggregator == address(0)) revert IErrors.ZeroAddress();
        if (tokenDecimals == 0) revert IErrors.InvalidAmount();
        feedOf[token] = OracleLib.ChainlinkFeed({
            aggregator: aggregator,
            staleAfter: staleAfter,
            tokenDecimals: tokenDecimals
        });
        emit FeedSet(token, aggregator, staleAfter, tokenDecimals);
    }

    // --- Guards ---

    /**
     * @notice Validate a swap plan against router whitelist and oracle-implied minimum output.
     * @param router    Swap router to be used (must be allowed).
     * @param tokenIn   Input token address.
     * @param tokenOut  Output token address.
     * @param amountIn  Input amount in tokenIn's native decimals.
     * @param minOut    Caller-provided minimum output (DEX slippage control).
     *
     * Reverts if:
     *  - Router is not allowed
     *  - Missing oracle config for either token
     *  - Oracle data is stale or invalid
     *  - minOut is below oracle-implied floor after configured slippage
     */
    function validateSwap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external view {
        if (!allowedRouters[router]) revert IErrors.RouterNotAllowed();

        OracleLib.ChainlinkFeed memory inFeed  = feedOf[tokenIn];
        OracleLib.ChainlinkFeed memory outFeed = feedOf[tokenOut];
        if (inFeed.aggregator == address(0) || outFeed.aggregator == address(0)) {
            revert IErrors.OracleOutOfBounds(); // treat as invalid config
        }

        uint16 bps = maxSlippageBps[tokenIn][tokenOut];
        // Require explicit slippage config; avoids silent permissiveness.
        if (bps == 0) revert IErrors.SlippageTooHigh();

        // Oracle-implied expected output in tokenOut units.
        uint256 expectedOut = OracleLib.getExpectedAmount(inFeed, outFeed, amountIn);
        if (expectedOut == 0) revert IErrors.OracleOutOfBounds();

        // Compute minimum allowed given slippage.
        uint256 minAllowed = (expectedOut * (BPS_DENOMINATOR - bps)) / BPS_DENOMINATOR;
        if (minOut < minAllowed) revert IErrors.SlippageTooHigh();
    }

    /**
     * @notice Helper: return the oracle-implied minimum out given a slippage bps.
     * @dev    Useful for keepers to pre-compute `minOut` before routing a swap.
     */
    function quoteMinOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 minOut) {
        OracleLib.ChainlinkFeed memory inFeed  = feedOf[tokenIn];
        OracleLib.ChainlinkFeed memory outFeed = feedOf[tokenOut];
        if (inFeed.aggregator == address(0) || outFeed.aggregator == address(0)) revert IErrors.OracleOutOfBounds();

        uint256 expectedOut = OracleLib.getExpectedAmount(inFeed, outFeed, amountIn);
        uint16 bps = maxSlippageBps[tokenIn][tokenOut];
        if (bps > 0) {
            minOut = (expectedOut * (BPS_DENOMINATOR - bps)) / BPS_DENOMINATOR;
        } else {
            minOut = expectedOut;
        }
    }
}
