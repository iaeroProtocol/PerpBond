// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../core/AccessRoles.sol";
import "../core/ErrorsEvents.sol";
import "../libs/SafeTransferLib.sol";
import "./IStrategyAdapter.sol";
import "./IVotingAdapter.sol";
import "./ILockingAdapter.sol";
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

/// @notice Aerodrome VotingEscrow interface for veAERO locking
/// @dev veAERO is implemented as NFTs, each representing a locked position
interface IVotingEscrow {
    /// @notice Create a new lock for `_value` AERO until `_lockDuration` seconds
    /// @return tokenId The NFT token ID for the created lock
    function createLock(uint256 _value, uint256 _lockDuration) external returns (uint256 tokenId);

    /// @notice Increase the amount of AERO locked in an existing position
    function increaseAmount(uint256 _tokenId, uint256 _value) external;

    /// @notice Increase the unlock time for an existing position
    function increaseUnlockTime(uint256 _tokenId, uint256 _lockDuration) external;

    /// @notice Withdraw all tokens for `_tokenId` after lock expires
    function withdraw(uint256 _tokenId) external;

    /// @notice Get the locked balance for a token ID
    function locked(uint256 _tokenId) external view returns (int128 amount, uint256 end);

    /// @notice Get voting power (balanceOfNFT) at current block
    function balanceOfNFT(uint256 _tokenId) external view returns (uint256);

    /// @notice Get owner of veNFT
    function ownerOf(uint256 _tokenId) external view returns (address);
}

/// @notice Aerodrome Voter interface for gauge voting
interface IVoter {
    /// @notice Vote for pools with veAERO voting power
    function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;

    /// @notice Reset votes for the current epoch
    function reset(uint256 _tokenId) external;

    /// @notice Claim bribes for voted gauges
    function claimBribes(address[] calldata _bribes, address[][] calldata _tokens, uint256 _tokenId) external;
}

/// @notice Aerodrome RewardsDistributor for claiming rebase rewards
interface IRewardsDistributor {
    /// @notice Claim rebase rewards for a veNFT
    function claim(uint256 _tokenId) external returns (uint256);
}

/// @title AerodromeVeAdapter (extended swap-enabled v2)
/// @notice Swaps USDC->AERO on deposit using Uniswap v3, locks to veAERO (NFT-based voting escrow),
///         reports TVL in USDC via RouterGuard oracles, votes on gauges, and harvests rebase + bribe rewards.
contract AerodromeVeAdapter is
    AccessRoles,
    ReentrancyGuard,
    IStrategyAdapter,
    IVotingAdapter,
    ILockingAdapter
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

    // Aerodrome Protocol Contracts (Base mainnet addresses)
    IVotingEscrow public votingEscrow;     // veAERO locking contract
    IVoter public voter;                    // Gauge voting contract
    IRewardsDistributor public rewardsDistributor; // Rebase rewards

    // veAERO NFT State
    uint256 public veNftTokenId;           // Our veAERO NFT token ID (0 = no lock yet)
    uint256 public lockDuration = 365 days; // Default lock duration (max = 4 years)

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
    event AeroLocked(uint256 indexed tokenId, uint256 amount, uint256 unlockTime);
    event LockIncreased(uint256 indexed tokenId, uint256 additionalAmount);
    event LockExtended(uint256 indexed tokenId, uint256 newUnlockTime);
    event RewardsClaimed(uint256 rebaseAmount, uint256 totalUsdcValue);
    event AerodromContractsSet(address votingEscrow, address voter, address rewardsDistributor);
    event LockDurationSet(uint256 oldDuration, uint256 newDuration);

    constructor(
        address governor_,
        address guardian_,
        address keeper_,
        address treasury_,
        address vault_,
        address usdc_,
        address aero_,
        address router_,
        address guard_,
        address votingEscrow_,
        address voter_,
        address rewardsDistributor_
    ) AccessRoles(governor_, guardian_, keeper_, treasury_) {
        if (vault_ == address(0) || usdc_ == address(0) || aero_ == address(0)) revert IErrors.ZeroAddress();
        vault = vault_;
        usdc = IERC20(usdc_);
        aero = IERC20(aero_);
        if (router_ != address(0)) swapRouter = ISwapRouterV3(router_);
        if (guard_   != address(0)) guard      = RouterGuard(guard_);
        if (votingEscrow_ != address(0)) votingEscrow = IVotingEscrow(votingEscrow_);
        if (voter_ != address(0)) voter = IVoter(voter_);
        if (rewardsDistributor_ != address(0)) rewardsDistributor = IRewardsDistributor(rewardsDistributor_);
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

    /// @notice Set Aerodrome protocol contracts for veAERO locking and voting
    function setAerodromeContracts(
        address votingEscrow_,
        address voter_,
        address rewardsDistributor_
    ) external onlyGovernor {
        if (votingEscrow_ != address(0)) votingEscrow = IVotingEscrow(votingEscrow_);
        if (voter_ != address(0)) voter = IVoter(voter_);
        if (rewardsDistributor_ != address(0)) rewardsDistributor = IRewardsDistributor(rewardsDistributor_);
        emit AerodromContractsSet(votingEscrow_, voter_, rewardsDistributor_);
    }

    /// @notice Set lock duration for new veAERO locks (between 1 week and 4 years)
    function setLockDuration(uint256 newDuration) external onlyGovernor {
        if (newDuration < 7 days || newDuration > 4 * 365 days) revert IErrors.InvalidAmount();
        uint256 old = lockDuration;
        lockDuration = newDuration;
        emit LockDurationSet(old, newDuration);
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

        // Lock AERO to veAERO if votingEscrow is configured
        if (address(votingEscrow) != address(0) && aeroOut > 0) {
            aero.safeApprove(address(votingEscrow), 0);
            aero.safeApprove(address(votingEscrow), aeroOut);

            if (veNftTokenId == 0) {
                // Create new lock
                uint256 unlockTime = block.timestamp + lockDuration;
                veNftTokenId = votingEscrow.createLock(aeroOut, lockDuration);
                emit AeroLocked(veNftTokenId, aeroOut, unlockTime);
            } else {
                // Increase existing lock amount
                votingEscrow.increaseAmount(veNftTokenId, aeroOut);
                emit LockIncreased(veNftTokenId, aeroOut);
            }
        }

        // Deployed notionally equals USDC contributed (consistent with USDC-based accounting).
        return usdcAmount;
    }

    /// @notice Harvest rebase rewards from veAERO and any pending AERO emissions
    /// @dev Claims rewards and returns AERO balance (caller should swap to USDC via Harvester)
    function harvest() external override nonReentrant returns (uint256 estimatedUsdcOut) {
        if (msg.sender != harvester && msg.sender != keeper) revert IErrors.Unauthorized();

        uint256 rebaseAmount;

        // Claim rebase rewards if we have a veNFT and rewardsDistributor is set
        if (veNftTokenId > 0 && address(rewardsDistributor) != address(0)) {
            try rewardsDistributor.claim(veNftTokenId) returns (uint256 claimed) {
                rebaseAmount = claimed;
            } catch {
                // Silent failure if claiming isn't available yet
            }
        }

        // Total AERO available to harvest (rebase + any idle AERO)
        uint256 aeroBalance = aero.balanceOf(address(this));

        // Estimate USD value if guard/oracle is available
        if (aeroBalance > 0 && address(guard) != address(0)) {
            estimatedUsdcOut = guard.quoteMinOut(address(aero), address(usdc), aeroBalance);
        }

        emit RewardsClaimed(rebaseAmount, estimatedUsdcOut);
        return estimatedUsdcOut;
    }

    /// @notice TVL in USDC terms = USDC balance + unlocked AERO + locked veAERO (oracle-quoted)
    function tvl() external view override returns (uint256) {
        uint256 usdcBal = usdc.balanceOf(address(this));
        uint256 aeroBal = aero.balanceOf(address(this));

        // Add locked veAERO balance if we have a lock
        if (veNftTokenId > 0 && address(votingEscrow) != address(0)) {
            try votingEscrow.locked(veNftTokenId) returns (int128 lockedAmount, uint256) {
                if (lockedAmount > 0) {
                    aeroBal += uint256(uint128(lockedAmount));
                }
            } catch {
                // Ignore if query fails
            }
        }

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

    /// @notice Vote on Aerodrome gauges with veAERO voting power
    /// @param gauges Array of pool addresses to vote for
    /// @param weights Array of weights (bps, should sum to 10000)
    function vote(address[] calldata gauges, uint256[] calldata weights) external override {
        if (msg.sender != voterRouter && msg.sender != keeper) revert IErrors.Unauthorized();
        if (gauges.length != weights.length) revert IErrors.InvalidAmount();
        if (veNftTokenId == 0) return; // No veNFT yet, nothing to vote with

        // Vote on Aerodrome gauges if voter contract is configured
        if (address(voter) != address(0)) {
            voter.vote(veNftTokenId, gauges, weights);
        }
    }

    /*--------------------------- ILockingAdapter -----------------------*/

    /// @notice Get the unlock time for our veAERO lock
    function lockedUntil() external view override returns (uint256) {
        if (veNftTokenId == 0 || address(votingEscrow) == address(0)) return 0;

        try votingEscrow.locked(veNftTokenId) returns (int128, uint256 unlockTime) {
            return unlockTime;
        } catch {
            return 0;
        }
    }

    /*--------------------------- Keeper helpers ------------------------*/

    /// @notice Extend the lock duration of our veAERO position to maintain voting power
    /// @dev Should be called periodically before lock expires to avoid loss of voting power
    function extendLock() external onlyKeeper whenNotPaused nonReentrant {
        if (veNftTokenId == 0) revert IErrors.InvalidAmount();
        if (address(votingEscrow) == address(0)) revert IErrors.ZeroAddress();

        uint256 newUnlockTime = block.timestamp + lockDuration;
        votingEscrow.increaseUnlockTime(veNftTokenId, lockDuration);
        emit LockExtended(veNftTokenId, newUnlockTime);
    }

    /// @notice Convert a portion of idle USDC held by the adapter to AERO and lock to veAERO.
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

        // Lock the swapped AERO to veAERO if configured
        if (address(votingEscrow) != address(0) && aeroOut > 0) {
            aero.safeApprove(address(votingEscrow), 0);
            aero.safeApprove(address(votingEscrow), aeroOut);

            if (veNftTokenId == 0) {
                uint256 unlockTime = block.timestamp + lockDuration;
                veNftTokenId = votingEscrow.createLock(aeroOut, lockDuration);
                emit AeroLocked(veNftTokenId, aeroOut, unlockTime);
            } else {
                votingEscrow.increaseAmount(veNftTokenId, aeroOut);
                emit LockIncreased(veNftTokenId, aeroOut);
            }
        }
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
