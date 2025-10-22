// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../core/AccessRoles.sol";
import "../core/ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";
import "./IStrategyAdapter.sol";
import "./IVotingAdapter.sol";
import "../core/RouterGuard.sol";

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

/// @title AerodromeVeAdapter (extended swap-enabled v2)
/// @notice Swaps USDC->AERO on deposit using Uniswap v3, reports TVL in USDC via RouterGuard oracles,
///         exposes harvest/vote hooks (no-op for now), and keeper utilities to convert/unwind.
contract AerodromeVeAdapter is
    AccessRoles,
    
    ReentrancyGuard,
    IStrategyAdapter,
    IVotingAdapter
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

    /*--------------------------- IVotingAdapter ------------------------*/

    /// @notice Governance voting hook (no-op until wired to protocol voter).
    function vote(address[] calldata /*gauges*/, uint256[] calldata /*weights*/) external override {
        if (msg.sender != voterRouter && msg.sender != keeper) revert IErrors.Unauthorized();
        // no-op for now; implement protocol-specific calls later
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
