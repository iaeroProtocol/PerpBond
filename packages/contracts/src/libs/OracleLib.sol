// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../core/ErrorsEvents.sol";

/// @notice Minimal Chainlink interface for spot price feeds.
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

/**
 * @title OracleLib
 * @notice Utilities for reading token/USD Chainlink feeds and quoting oracle-implied swap outputs.
 *
 * Assumptions:
 * - Each configured feed returns "USD per 1 token" (e.g., ETH/USD, USDC/USD).
 * - Feeds may have different decimals (commonly 8). We normalize to 1e18 for math.
 * - Staleness is enforced via a per-token window (`staleAfter` seconds).
 *
 * If you must support an inverse feed (USD/token), either configure the proper forward feed
 * or wrap/transform externally before calling into this library.
 */
library OracleLib {
    struct ChainlinkFeed {
        address aggregator;  // Chainlink AggregatorV3 address for token/USD
        uint48  staleAfter;  // Max allowed staleness in seconds (0 = no staleness check)
        uint8   tokenDecimals; // Native decimals of the ERC-20 token (e.g., USDC=6, WETH=18)
    }

    /**
     * @notice Return the oracle-implied output amount for swapping `amountIn` of tokenIn
     *         to tokenOut, based on token/USD Chainlink feeds for each side.
     * @param inFeed   Chainlink feed config for tokenIn (tokenIn/USD)
     * @param outFeed  Chainlink feed config for tokenOut (tokenOut/USD)
     * @param amountIn Input amount in tokenIn's native decimals
     * @return expectedOut Amount of tokenOut (in tokenOut's native decimals)
     *
     * Math (all prices normalized to 1e18):
     *   USD value = amountIn / 10^decIn * priceIn
     *   expectedOut = USD value / priceOut * 10^decOut
     *               = amountIn * priceIn * 10^decOut / (10^decIn * priceOut)
     */
    function getExpectedAmount(
        ChainlinkFeed memory inFeed,
        ChainlinkFeed memory outFeed,
        uint256 amountIn
    ) internal view returns (uint256 expectedOut) {
        if (inFeed.aggregator == address(0) || outFeed.aggregator == address(0)) {
            revert IErrors.OracleOutOfBounds();
        }
        if (amountIn == 0) return 0;

        uint256 priceInWad  = _readPriceWad(inFeed);   // USD per tokenIn, 1e18
        uint256 priceOutWad = _readPriceWad(outFeed);  // USD per tokenOut, 1e18
        if (priceOutWad == 0) revert IErrors.OracleOutOfBounds();

        uint256 decIn  = 10 ** uint256(inFeed.tokenDecimals);
        uint256 decOut = 10 ** uint256(outFeed.tokenDecimals);

        // expectedOut = (amountIn * priceInWad / 10^decIn) * 10^decOut / priceOutWad
        uint256 usdValueWad = Math.mulDiv(amountIn, priceInWad, decIn);
        expectedOut = Math.mulDiv(usdValueWad, decOut, priceOutWad);
    }

    /**
     * @notice Read a Chainlink token/USD price and return it normalized to 1e18.
     * @dev Reverts on stale/invalid data. Treats `staleAfter == 0` as "no staleness check".
     */
    function _readPriceWad(ChainlinkFeed memory feed) private view returns (uint256) {
        AggregatorV3Interface agg = AggregatorV3Interface(feed.aggregator);

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = agg.latestRoundData();

        if (answer <= 0) revert IErrors.OracleOutOfBounds();
        if (answeredInRound < roundId) revert IErrors.OracleOutOfBounds();
        if (feed.staleAfter != 0 && block.timestamp - updatedAt > feed.staleAfter) {
            revert IErrors.OracleOutOfBounds();
        }

        uint8 pDec = agg.decimals(); // feed decimals (commonly 8)
        uint256 price = uint256(answer);

        // Normalize price to 1e18
        if (pDec < 18) {
            price = price * (10 ** uint256(18 - pDec));
        } else if (pDec > 18) {
            price = price / (10 ** uint256(pDec - 18));
        }
        return price; // 1e18-scaled USD per 1 token
    }
}
