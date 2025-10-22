// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./AccessRoles.sol";
import "./ErrorsEvents.sol";
import "./SafeTransferLib.sol";
import "./AdapterRegistry.sol";
import "./PerpBondVault.sol";
import "./IStrategyAdapter.sol";

/// @notice Minimal interface for a pluggable swapper that converts reward tokens to USDC.
interface IRewardSwapper {
    /// @param token       Reward token to convert from.
    /// @param amountIn    Amount of `token` to swap.
    /// @param minUsdcOut  Slippage floor in USDC (6 decimals).
    /// @param recipient   Destination for USDC proceeds (Harvester).
    /// @return usdcOut    Amount of USDC (6 decimals) received.
    function swapToUSDC(
        address token,
        uint256 amountIn,
        uint256 minUsdcOut,
        address recipient
    ) external returns (uint256 usdcOut);
}

/**
 * @title Harvester
 * @notice Orchestrates reward harvesting from adapters and converts rewards to USDC.
 *         Distributor later pulls USDC from this contract to close epochs.
 */
contract Harvester is AccessRoles, ErrorsEvents, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    // Core contracts
    PerpBondVault public vault;
    AdapterRegistry public registry;
    IERC20 public immutable usdc;

    // Distributor (pulls USDC via transferFrom)
    address public distributor;

    // token => swapper contract
    mapping(address => address) public swapperFor;

    // Events
    event VaultSet(address indexed oldVault, address indexed newVault);
    event RegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event DistributorSet(address indexed oldDistributor, address indexed newDistributor);
    event SwapperSet(address indexed token, address indexed swapper);
    event AdapterHarvested(address indexed adapter, uint256 estimatedUsdc);
    event RewardsSwapped(address indexed token, address indexed swapper, uint256 amountIn, uint256 usdcOut);
    event HarvestAll(uint256 adaptersProcessed, uint256 totalEstimatedUsdc);

    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address vault_,
        address registry_,
        address distributor_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (vault_ == address(0) || registry_ == address(0)) revert IErrors.ZeroAddress();

        vault = PerpBondVault(vault_);
        registry = AdapterRegistry(registry_);
        usdc = vault.usdc();

        if (distributor_ != address(0)) {
            distributor = distributor_;
            // Pre-approve Distributor to pull USDC (Distributor uses transferFrom during closeEpoch).
            usdc.safeApprove(distributor_, 0);
            usdc.safeApprove(distributor_, type(uint256).max);
        }
    }

    /* -------------------------------- Admin -------------------------------- */

    function setVault(address newVault) external onlyGovernor {
        if (newVault == address(0)) revert IErrors.ZeroAddress();
        address old = address(vault);
        vault = PerpBondVault(newVault);
        emit VaultSet(old, newVault);
    }

    function setRegistry(address newRegistry) external onlyGovernor {
        if (newRegistry == address(0)) revert IErrors.ZeroAddress();
        address old = address(registry);
        registry = AdapterRegistry(newRegistry);
        emit RegistrySet(old, newRegistry);
    }

    function setDistributor(address newDistributor) external onlyGovernor {
        address old = distributor;

        // Clear old allowance, set new max allowance.
        if (old != address(0)) usdc.safeApprove(old, 0);
        distributor = newDistributor;
        if (newDistributor != address(0)) {
            usdc.safeApprove(newDistributor, 0);
            usdc.safeApprove(newDistributor, type(uint256).max);
        }

        emit DistributorSet(old, newDistributor);
    }

    /// @notice Set/clear a swapper for a given reward token (zero to unset).
    function setSwapper(address token, address swapper) external onlyGovernor {
        if (token == address(0)) revert IErrors.ZeroAddress();
        swapperFor[token] = swapper; // may be zero to disable
        emit SwapperSet(token, swapper);
    }

    /// @notice Rescue any token mistakenly sent here (including rewards you decide not to swap).
    function rescueToken(address token, address to, uint256 amount) external onlyGovernor {
        if (token == address(0) || to == address(0)) revert IErrors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /* ------------------------------- Harvesting ----------------------------- */

    /// @notice Harvest rewards from all ACTIVE adapters.
    /// @dev    Adapters may transfer reward tokens to this contract and/or return an estimated USDC value.
    function harvestAll() external onlyKeeper whenNotPaused nonReentrant returns (uint256 totalEstimatedUsdc) {
        address[] memory adapters = registry.getActiveAdapters();
        uint256 n = adapters.length;

        for (uint256 i = 0; i < n; ++i) {
            uint256 est = IStrategyAdapter(adapters[i]).harvest();
            totalEstimatedUsdc += est;
            emit AdapterHarvested(adapters[i], est);
        }

        emit HarvestAll(n, totalEstimatedUsdc);
    }

    /* -------------------------------- Swapping ------------------------------ */

    /// @notice Swap current balances of the provided reward tokens to USDC using configured swappers.
    /// @param  tokens      Reward tokens to convert.
    /// @param  minUsdcOut  Per-token slippage floors (6 decimals).
    /// @return totalOut    Total USDC realized across all swaps.
    function swapRewards(address[] calldata tokens, uint256[] calldata minUsdcOut)
        external
        onlyKeeper
        whenNotPaused
        nonReentrant
        returns (uint256 totalOut)
    {
        if (tokens.length != minUsdcOut.length) revert IErrors.InvalidAmount();

        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            address swapper = swapperFor[token];
            if (swapper == address(0)) continue; // No swapper configured; skip.

            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;

            // Approve swapper and execute swap to USDC.
            IERC20(token).safeApprove(swapper, 0);
            IERC20(token).safeApprove(swapper, bal);
            uint256 out = IRewardSwapper(swapper).swapToUSDC(token, bal, minUsdcOut[i], address(this));

            totalOut += out;
            emit RewardsSwapped(token, swapper, bal, out);
        }
    }

    /* --------------------------------- Views -------------------------------- */

    function usdcBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
