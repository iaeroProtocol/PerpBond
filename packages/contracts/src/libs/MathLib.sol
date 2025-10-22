// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MathLib
/// @notice BPS arithmetic, fixed-point helpers (WAD/RAY), and ERC-4626-style share math
/// @dev    Used by the Vault (deposit/share conversion, allocations) and Distributor (epoch ratios).
library MathLib {
    /*//////////////////////////////////////////////////////////////
                               Constants
    //////////////////////////////////////////////////////////////*/
    uint256 internal constant BPS = 10_000;  // 100% in basis points
    uint256 internal constant WAD = 1e18;    // 18-dec fixed-point
    uint256 internal constant RAY = 1e27;    // 27-dec fixed-point

    // Per system design: USDC (6) in, receipt token (18) out.
    uint8  internal constant USDC_DECIMALS   = 6;
    uint8  internal constant SHARES_DECIMALS = 18;

    uint256 internal constant ASSET_UNIT = 10 ** USDC_DECIMALS;    // 1e6
    uint256 internal constant SHARE_UNIT = 10 ** SHARES_DECIMALS;  // 1e18
    uint256 internal constant SCALE      = SHARE_UNIT / ASSET_UNIT; // 1e12 (6 -> 18)

    /*//////////////////////////////////////////////////////////////
                           MulDiv (512-bit)
    //////////////////////////////////////////////////////////////*/

    /// @notice x * y / d (round down).
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(x, y, d);
    }

    /// @notice ceil(x * y / d).
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(x, y, d, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                              BPS helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns amount * bps / 10_000.
    function mulBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, BPS);
    }

    /// @notice Alias for mulBps (percent-of helper).
    function percentOf(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, BPS);
    }

    /*//////////////////////////////////////////////////////////////
                         Fixed-point conveniences
    //////////////////////////////////////////////////////////////*/

    function wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, WAD);
    }

    function wdiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, WAD, y);
    }

    function rmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, y, RAY);
    }

    function rdiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return Math.mulDiv(x, RAY, y);
    }

    /*//////////////////////////////////////////////////////////////
                        Decimals & unit conversion
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC(6) -> WAD(18).
    function usdcToWad(uint256 usdc) internal pure returns (uint256) {
        return usdc * (WAD / ASSET_UNIT); // 1e12 scale-up
    }

    /// @notice WAD(18) -> USDC(6), rounds down.
    function wadToUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / (WAD / ASSET_UNIT); // 1e12 scale-down
    }

    /// @notice Assets (USDC, 6) -> Shares (18).
    function assetsToShares(uint256 assets) internal pure returns (uint256) {
        return assets * SCALE; // 6 -> 18
    }

    /// @notice Shares (18) -> Assets (USDC, 6), rounds down.
    function sharesToAssets(uint256 shares) internal pure returns (uint256) {
        return shares / SCALE; // 18 -> 6
    }

    /*//////////////////////////////////////////////////////////////
                            Share conversion
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert assets (USDC, 6) to shares (18) using ERC-4626-style math.
    /// @dev If supply == 0 or totalAssets == 0: bootstrap at 1:1 after decimal scaling.
    function convertToShares(
        uint256 assets,
        uint256 totalAssets_,
        uint256 totalShares_
    ) internal pure returns (uint256 shares) {
        if (assets == 0) return 0;
        if (totalShares_ == 0 || totalAssets_ == 0) {
            // Bootstrap: 1 USDC -> 1 share (after decimals; i.e., *1e12)
            return assetsToShares(assets);
        }
        // Normal path: shares = assets * totalShares / totalAssets
        return Math.mulDiv(assets, totalShares_, totalAssets_);
    }

    /// @notice Convert shares (18) to assets (USDC, 6) using ERC-4626-style math.
    function convertToAssets(
        uint256 shares,
        uint256 totalAssets_,
        uint256 totalShares_
    ) internal pure returns (uint256 assets) {
        if (shares == 0 || totalShares_ == 0) return 0;
        // assets = shares * totalAssets / totalShares
        return Math.mulDiv(shares, totalAssets_, totalShares_);
    }

    /*//////////////////////////////////////////////////////////////
                       Epoch accounting convenience
    //////////////////////////////////////////////////////////////*/

    /// @notice Compute USDC-per-share as a RAY (1e27) with decimals aligned.
    /// @dev    Converts USDC(6) -> WAD(18) before producing a dimensionless RAY ratio.
    function usdcPerShareRay(uint256 netUsdc, uint256 totalShares_) internal pure returns (uint256) {
        if (netUsdc == 0 || totalShares_ == 0) return 0;
        uint256 netUsdcWad = usdcToWad(netUsdc);               // 6 -> 18
        return Math.mulDiv(netUsdcWad, RAY, totalShares_);     // (USDC_18 / shares_18) * 1e27
    }
}
