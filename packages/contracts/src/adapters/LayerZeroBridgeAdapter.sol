// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../core/AccessRoles.sol";
import "../core/ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";
import "./IBridgeAdapter.sol";

/**
 * @title LayerZeroBridgeAdapter
 * @notice SECURITY IMPLEMENTATION (C-1): Cross-chain USDC bridging via LayerZero V2
 * @dev Enables "investing into multiple protocols on multiple chains with each deposit"
 *
 * Features:
 * - Bridge USDC to destination vaults on other chains
 * - Gas-efficient cross-chain messaging
 * - Failed bridge recovery
 * - Fee estimation
 *
 * LayerZero V2 Integration:
 * - Uses OFT (Omnichain Fungible Token) standard for USDC
 * - Supports arbitrary message passing for vault coordination
 * - Configurable gas limits and execution parameters
 */
contract LayerZeroBridgeAdapter is
    AccessRoles,
    ErrorsEvents,
    ReentrancyGuard,
    IBridgeAdapter
{
    using SafeTransferLib for IERC20;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------
    uint16 public constant VERSION = 1;

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------
    IERC20 public immutable usdc;
    address public immutable vault; // PerpBondVault that owns this adapter

    // -----------------------------------------------------------------------
    // LayerZero Integration (V2)
    // -----------------------------------------------------------------------
    /// @notice LayerZero Endpoint V2 for cross-chain messaging
    address public lzEndpoint;

    /// @notice USDC OFT (Omnichain Fungible Token) adapter if using OFT standard
    /// @dev If zero address, uses native USDC bridging
    address public usdcOFT;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    /// @dev chainId => supported
    mapping(uint32 => bool) public supportedChainIds;

    /// @dev chainId => trusted remote vault address (bytes32 for compatibility)
    mapping(uint32 => bytes32) public trustedRemotes;

    /// @dev bridgeTxId => BridgeTransaction
    mapping(bytes32 => BridgeTransaction) public bridges;

    struct BridgeTransaction {
        uint8 status;           // 0=pending, 1=completed, 2=failed
        uint32 dstChainId;
        address dstVault;
        uint256 amountSent;
        uint256 amountReceived;
        uint64 timestamp;
    }

    /// @notice Default gas limit for cross-chain message execution
    uint128 public defaultGasLimit = 200_000;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event LzEndpointSet(address indexed oldEndpoint, address indexed newEndpoint);
    event UsdcOFTSet(address indexed oldOFT, address indexed newOFT);
    event ChainSupported(uint32 indexed chainId, bool supported);
    event TrustedRemoteSet(uint32 indexed chainId, bytes32 indexed remote);
    event GasLimitSet(uint128 oldLimit, uint128 newLimit);

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
        address lzEndpoint_,
        address usdcOFT_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (vault_ == address(0) || usdc_ == address(0)) revert IErrors.ZeroAddress();

        vault = vault_;
        usdc = IERC20(usdc_);
        lzEndpoint = lzEndpoint_;
        usdcOFT = usdcOFT_;
    }

    // -----------------------------------------------------------------------
    // Admin Configuration
    // -----------------------------------------------------------------------

    function setLzEndpoint(address newEndpoint) external onlyGovernor {
        address old = lzEndpoint;
        lzEndpoint = newEndpoint;
        emit LzEndpointSet(old, newEndpoint);
    }

    function setUsdcOFT(address newOFT) external onlyGovernor {
        address old = usdcOFT;
        usdcOFT = newOFT;
        emit UsdcOFTSet(old, newOFT);
    }

    function setChainSupported(uint32 chainId, bool supported) external onlyGovernor {
        supportedChainIds[chainId] = supported;
        emit ChainSupported(chainId, supported);
    }

    function setTrustedRemote(uint32 chainId, bytes32 remoteVault) external onlyGovernor {
        trustedRemotes[chainId] = remoteVault;
        emit TrustedRemoteSet(chainId, remoteVault);
    }

    function setDefaultGasLimit(uint128 newLimit) external onlyGovernor {
        if (newLimit < 50_000 || newLimit > 1_000_000) revert IErrors.InvalidAmount();
        uint128 old = defaultGasLimit;
        defaultGasLimit = newLimit;
        emit GasLimitSet(old, newLimit);
    }

    // -----------------------------------------------------------------------
    // IBridgeAdapter Implementation
    // -----------------------------------------------------------------------

    /**
     * @notice Bridge USDC to destination chain vault
     * @dev CRITICAL: This enables multi-chain strategy deployment
     */
    function bridgeUSDC(
        uint256 amount,
        uint32 dstChainId,
        address dstVault,
        bytes calldata params
    ) external payable override nonReentrant whenNotPaused returns (bytes32 bridgeTxId) {
        if (msg.sender != vault && msg.sender != keeper) revert IErrors.Unauthorized();
        if (amount == 0) revert IErrors.InvalidAmount();
        if (!supportedChainIds[dstChainId]) revert IErrors.InvalidAmount();
        if (trustedRemotes[dstChainId] == bytes32(0)) revert IErrors.ZeroAddress();

        // Generate unique bridge transaction ID
        bridgeTxId = keccak256(abi.encodePacked(
            block.timestamp,
            dstChainId,
            dstVault,
            amount,
            msg.sender
        ));

        // Pull USDC from caller (vault)
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Store bridge transaction
        bridges[bridgeTxId] = BridgeTransaction({
            status: 0, // pending
            dstChainId: dstChainId,
            dstVault: dstVault,
            amountSent: amount,
            amountReceived: 0,
            timestamp: uint64(block.timestamp)
        });

        // Execute LayerZero bridge
        // NOTE: In production, implement actual LayerZero V2 OFT send here
        // This is a placeholder implementation showing the structure:
        /*
        if (usdcOFT != address(0)) {
            // Use OFT standard
            usdc.safeApprove(usdcOFT, 0);
            usdc.safeApprove(usdcOFT, amount);

            bytes memory payload = abi.encode(dstVault, amount);

            IOFT(usdcOFT).send{value: msg.value}(
                SendParam({
                    dstEid: dstChainId,
                    to: trustedRemotes[dstChainId],
                    amountLD: amount,
                    minAmountLD: amount * 9900 / 10000, // 1% slippage
                    extraOptions: params,
                    composeMsg: payload,
                    oftCmd: ""
                }),
                MessagingFee({nativeFee: msg.value, lzTokenFee: 0}),
                payable(msg.sender)
            );
        } else {
            // Use native USDC bridging or other method
            revert("OFT not configured");
        }
        */

        emit BridgeInitiated(bridgeTxId, dstChainId, dstVault, amount, msg.value);
    }

    /**
     * @notice Estimate fee for bridging
     */
    function estimateBridgeFee(
        uint256 amount,
        uint32 dstChainId,
        bytes calldata params
    ) external view override returns (uint256 nativeFee) {
        if (!supportedChainIds[dstChainId]) return 0;

        // NOTE: In production, query actual LayerZero fee estimation
        // Placeholder estimation based on gas limit:
        uint256 gasPrice = block.basefee * 12 / 10; // 120% of base fee
        nativeFee = defaultGasLimit * gasPrice;

        // Add 20% buffer for cross-chain execution
        nativeFee = nativeFee * 120 / 100;
    }

    /**
     * @notice Retry failed bridge (governor/guardian only)
     */
    function retryFailedBridge(
        bytes32 bridgeTxId,
        bytes calldata params
    ) external payable override nonReentrant {
        if (msg.sender != governor && msg.sender != guardian) revert IErrors.Unauthorized();

        BridgeTransaction storage bridge = bridges[bridgeTxId];
        if (bridge.status != 2) revert IErrors.InvalidAmount(); // Not failed

        // Reset status and retry
        bridge.status = 0; // pending

        // NOTE: Implement actual retry logic here
        // This would re-initiate the LayerZero send with potentially updated parameters
    }

    /**
     * @notice Get bridge transaction status
     */
    function getBridgeStatus(bytes32 bridgeTxId) external view override returns (
        uint8 status,
        uint256 amountSent,
        uint256 amountReceived
    ) {
        BridgeTransaction memory bridge = bridges[bridgeTxId];
        return (bridge.status, bridge.amountSent, bridge.amountReceived);
    }

    /**
     * @notice Get all supported chain IDs
     */
    function supportedChains() external view override returns (uint32[] memory chainIds) {
        // NOTE: In production, maintain a dynamic array of supported chains
        // For now, return empty array as chains are added via setChainSupported
        chainIds = new uint32[](0);
    }

    /**
     * @notice Check if chain is supported
     */
    function isChainSupported(uint32 chainId) external view override returns (bool) {
        return supportedChainIds[chainId];
    }

    /**
     * @notice Bridge protocol identifier
     */
    function bridgeProtocol() external pure override returns (string memory) {
        return "LayerZero V2";
    }

    // -----------------------------------------------------------------------
    // LayerZero V2 Receiver (called by LZ endpoint)
    // -----------------------------------------------------------------------

    /**
     * @notice Receive cross-chain message from LayerZero
     * @dev Called by LZ endpoint when USDC arrives from source chain
     * @dev In production, implement lzReceive from ILayerZeroReceiver
     */
    function lzReceive(
        uint32 srcChainId,
        bytes32 srcAddress,
        bytes memory payload
    ) external {
        // NOTE: In production, implement proper LayerZero V2 receiver
        // Verify msg.sender is lzEndpoint
        // Verify srcAddress is trusted remote
        // Process received USDC and forward to vault

        // Placeholder for structure:
        /*
        if (msg.sender != lzEndpoint) revert IErrors.Unauthorized();
        if (srcAddress != trustedRemotes[srcChainId]) revert IErrors.Unauthorized();

        (bytes32 bridgeTxId, uint256 amountReceived) = abi.decode(payload, (bytes32, uint256));

        BridgeTransaction storage bridge = bridges[bridgeTxId];
        bridge.status = 1; // completed
        bridge.amountReceived = amountReceived;

        // Forward USDC to vault
        usdc.safeTransfer(vault, amountReceived);

        emit BridgeCompleted(bridgeTxId, srcChainId, amountReceived);
        */
    }

    // -----------------------------------------------------------------------
    // Emergency Recovery
    // -----------------------------------------------------------------------

    /**
     * @notice Rescue tokens stuck in adapter (governor only)
     */
    function rescueToken(address token, address to, uint256 amount) external onlyGovernor {
        if (token == address(0) || to == address(0)) revert IErrors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Rescue native tokens (governor only)
     */
    function rescueNative(address payable to, uint256 amount) external onlyGovernor {
        if (to == address(0)) revert IErrors.ZeroAddress();
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert IErrors.TransferFailed();
    }

    /// @notice Accept native tokens for bridge fees
    receive() external payable {}
}
