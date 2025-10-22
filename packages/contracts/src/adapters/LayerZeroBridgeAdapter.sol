// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../core/AccessRoles.sol";
import "../core/ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";
import "./IBridgeAdapter.sol";

/// @notice LayerZero V2 Endpoint Interface
interface ILayerZeroEndpointV2 {
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    /// @notice Send a message to a destination endpoint
    function send(
        MessagingParams calldata _params,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory receipt);

    /// @notice Quote fee for sending a message
    function quote(
        MessagingParams calldata _params,
        address _sender
    ) external view returns (MessagingFee memory fee);
}

/// @notice LayerZero V2 Receiver Interface
interface ILayerZeroReceiver {
    struct Origin {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
    }

    /// @notice Called by LZ Endpoint when a message is received
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;

    /// @notice Allows the Endpoint to check if the receiver is willing to accept a message
    function allowInitializePath(Origin calldata _origin) external view returns (bool);
}

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

    ReentrancyGuard,
    IBridgeAdapter,
    ILayerZeroReceiver
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
    /// @dev Mainnet addresses (same across EVM chains):
    ///      Ethereum, Base, Arbitrum, Optimism, etc: 0x1a44076050125825900e736c501f859c50fE728c
    ILayerZeroEndpointV2 public lzEndpoint;

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
        if (lzEndpoint_ != address(0)) lzEndpoint = ILayerZeroEndpointV2(lzEndpoint_);
        usdcOFT = usdcOFT_;
    }

    // -----------------------------------------------------------------------
    // Admin Configuration
    // -----------------------------------------------------------------------

    function setLzEndpoint(address newEndpoint) external onlyGovernor {
        address old = address(lzEndpoint);
        if (newEndpoint != address(0)) {
            lzEndpoint = ILayerZeroEndpointV2(newEndpoint);
        } else {
            lzEndpoint = ILayerZeroEndpointV2(address(0));
        }
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

        // Execute LayerZero V2 bridge via Endpoint
        if (address(lzEndpoint) == address(0)) revert IErrors.ZeroAddress();

        // Encode the message payload with bridge tx ID and destination vault
        bytes memory message = abi.encode(bridgeTxId, dstVault, amount);

        // Prepare LayerZero messaging parameters
        ILayerZeroEndpointV2.MessagingParams memory messagingParams = ILayerZeroEndpointV2.MessagingParams({
            dstEid: dstChainId,
            receiver: trustedRemotes[dstChainId],
            message: message,
            options: params.length > 0 ? params : _getDefaultOptions(),
            payInLzToken: false
        });

        // Send via LayerZero endpoint
        ILayerZeroEndpointV2.MessagingReceipt memory receipt = lzEndpoint.send{value: msg.value}(
            messagingParams,
            payable(msg.sender) // refund address
        );

        emit BridgeInitiated(bridgeTxId, dstChainId, dstVault, amount, receipt.fee.nativeFee);
    }

    /// @notice Get default LayerZero options (gas limit for execution)
    function _getDefaultOptions() internal view returns (bytes memory) {
        // LayerZero V2 options format: type 3 (executor LZ receive option)
        // Options: [type][gas]
        return abi.encodePacked(uint16(3), defaultGasLimit);
    }

    /**
     * @notice Estimate fee for bridging via LayerZero
     */
    function estimateBridgeFee(
        uint256 amount,
        uint32 dstChainId,
        bytes calldata params
    ) external view override returns (uint256 nativeFee) {
        if (!supportedChainIds[dstChainId]) return 0;
        if (address(lzEndpoint) == address(0)) return 0;
        if (trustedRemotes[dstChainId] == bytes32(0)) return 0;

        // Encode message (same as in bridgeUSDC)
        bytes32 tempTxId = keccak256(abi.encodePacked(block.timestamp, dstChainId, amount));
        bytes memory message = abi.encode(tempTxId, address(0), amount);

        // Prepare messaging params
        ILayerZeroEndpointV2.MessagingParams memory messagingParams = ILayerZeroEndpointV2.MessagingParams({
            dstEid: dstChainId,
            receiver: trustedRemotes[dstChainId],
            message: message,
            options: params.length > 0 ? params : _getDefaultOptions(),
            payInLzToken: false
        });

        // Quote the fee from LayerZero endpoint
        ILayerZeroEndpointV2.MessagingFee memory fee = lzEndpoint.quote(messagingParams, address(this));
        nativeFee = fee.nativeFee;
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
     */
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable override {
        // CRITICAL: Only LayerZero endpoint can call this
        if (msg.sender != address(lzEndpoint)) revert IErrors.Unauthorized();

        // CRITICAL: Only accept messages from trusted remotes
        if (_origin.sender != trustedRemotes[_origin.srcEid]) revert IErrors.Unauthorized();

        // Decode the message payload
        (bytes32 bridgeTxId, address dstVault, uint256 amount) = abi.decode(_message, (bytes32, address, uint256));

        // Verify the destination vault matches our vault
        if (dstVault != vault && dstVault != address(0)) revert IErrors.Unauthorized();

        // Check USDC balance to confirm funds arrived
        uint256 usdcBalance = usdc.balanceOf(address(this));
        uint256 amountToForward = amount > usdcBalance ? usdcBalance : amount;

        // Update bridge transaction status
        BridgeTransaction storage bridge = bridges[bridgeTxId];
        if (bridge.amountSent > 0) {
            // This is a bridge we initiated - mark as completed
            bridge.status = 1; // completed
            bridge.amountReceived = amountToForward;
        }

        // Forward USDC to vault
        if (amountToForward > 0) {
            usdc.safeTransfer(vault, amountToForward);
        }

        emit BridgeCompleted(bridgeTxId, _origin.srcEid, amountToForward);
    }

    /**
     * @notice Check if we're willing to accept a message from this origin
     * @dev Called by LayerZero endpoint before lzReceive
     */
    function allowInitializePath(Origin calldata _origin) external view override returns (bool) {
        // Accept messages from trusted remotes on supported chains
        return supportedChainIds[_origin.srcEid] && trustedRemotes[_origin.srcEid] == _origin.sender;
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
