// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IBridgeAdapter
 * @notice Interface for cross-chain bridge adapters to support multi-chain protocol deployments.
 * @dev SECURITY IMPLEMENTATION (C-1): This interface enables the critical requirement of
 *      "investing into multiple protocols on multiple chains with each deposit"
 *
 * Implementing contracts: LayerZeroBridgeAdapter, AxelarBridgeAdapter, WormholeBridgeAdapter
 */
interface IBridgeAdapter {
    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event BridgeInitiated(
        bytes32 indexed bridgeTxId,
        uint32 indexed dstChainId,
        address indexed dstVault,
        uint256 amount,
        uint256 nativeFee
    );

    event BridgeCompleted(
        bytes32 indexed bridgeTxId,
        uint32 srcChainId,
        uint256 amountReceived
    );

    event BridgeFailed(
        bytes32 indexed bridgeTxId,
        uint32 dstChainId,
        bytes reason
    );

    // -----------------------------------------------------------------------
    // Core Bridge Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Bridge USDC to a destination chain and vault
     * @param amount Amount of USDC (6 decimals) to bridge
     * @param dstChainId Destination chain ID (LayerZero format)
     * @param dstVault Destination vault address on target chain
     * @param params Bridge-specific encoded parameters
     * @return bridgeTxId Unique identifier for tracking this bridge transaction
     * @dev Caller must approve this contract for `amount` USDC before calling
     * @dev msg.value must cover native fee (use estimateBridgeFee first)
     */
    function bridgeUSDC(
        uint256 amount,
        uint32 dstChainId,
        address dstVault,
        bytes calldata params
    ) external payable returns (bytes32 bridgeTxId);

    /**
     * @notice Estimate native token fee required for bridging
     * @param amount Amount of USDC to bridge
     * @param dstChainId Destination chain ID
     * @param params Bridge-specific parameters
     * @return nativeFee Native token amount needed (msg.value)
     */
    function estimateBridgeFee(
        uint256 amount,
        uint32 dstChainId,
        bytes calldata params
    ) external view returns (uint256 nativeFee);

    // -----------------------------------------------------------------------
    // Recovery & Admin
    // -----------------------------------------------------------------------

    /**
     * @notice Retry a failed bridge transaction
     * @param bridgeTxId Original bridge transaction ID
     * @param params Updated parameters for retry
     * @dev Only callable by vault governor/guardian
     */
    function retryFailedBridge(
        bytes32 bridgeTxId,
        bytes calldata params
    ) external payable;

    /**
     * @notice Query status of a bridge transaction
     * @param bridgeTxId Bridge transaction ID
     * @return status 0=pending, 1=completed, 2=failed
     * @return amountSent Amount sent from source
     * @return amountReceived Amount received at destination (0 if pending/failed)
     */
    function getBridgeStatus(bytes32 bridgeTxId) external view returns (
        uint8 status,
        uint256 amountSent,
        uint256 amountReceived
    );

    // -----------------------------------------------------------------------
    // Metadata
    // -----------------------------------------------------------------------

    /**
     * @notice Supported destination chains
     * @return chainIds Array of supported LayerZero chain IDs
     */
    function supportedChains() external view returns (uint32[] memory chainIds);

    /**
     * @notice Check if a chain is supported
     * @param chainId LayerZero chain ID to check
     * @return supported True if chain is supported
     */
    function isChainSupported(uint32 chainId) external view returns (bool supported);

    /**
     * @notice Bridge protocol name (e.g., "LayerZero", "Axelar", "Wormhole")
     */
    function bridgeProtocol() external pure returns (string memory);
}
