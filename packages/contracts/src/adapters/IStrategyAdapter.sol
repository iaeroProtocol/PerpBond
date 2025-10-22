// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for strategy adapters used by the PerpBond Vault.
/// @dev All amounts are USDC with 6 decimals unless noted.
interface IStrategyAdapter {
    /// @notice Deploy `usdcAmount` from the adapter into the strategy.
    /// @return deployedUsdc USDC-equivalent notionally deployed (6 decimals).
    function deposit(uint256 usdcAmount) external returns (uint256 deployedUsdc);

    /// @notice Harvest pending rewards and make them available for swapping.
    /// @return estimatedUsdcOut Estimated or realized USDC amount (6 decimals).
    function harvest() external returns (uint256 estimatedUsdcOut);

    /// @notice Current USDC value (6 decimals) of this adapter’s position.
    function tvl() external view returns (uint256);

    /// @notice Emergency unwind; best-effort recovery back to USDC.
    /// @return recoveredUsdc USDC recovered (6 decimals).
    function emergencyWithdraw() external returns (uint256 recoveredUsdc);

    /// @notice Human-readable adapter name (e.g., "Aerodrome veAERO").
    function name() external view returns (string memory);

    /// @notice Main underlying token held (address(0) if entirely USDC).
    function underlyingToken() external view returns (address);
}
