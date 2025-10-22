# PerpBond Security Audit Report

**Date:** 2025-10-22
**Auditor:** Claude Code
**Scope:** All smart contracts in packages/contracts/src/

---

## Executive Summary

This audit identified **CRITICAL** security vulnerabilities and missing functionality that must be addressed before deployment. The protocol is designed to accept USDC deposits and invest across multiple protocols on multiple chains, but **cross-chain bridging infrastructure is completely missing**.

### Severity Breakdown
- **CRITICAL**: 8 issues
- **HIGH**: 7 issues
- **MEDIUM**: 5 issues
- **LOW**: 4 issues

---

## CRITICAL ISSUES

### C-1: Missing Cross-Chain Bridging Infrastructure
**Severity:** CRITICAL
**Status:** NOT IMPLEMENTED
**Location:** Entire protocol

**Description:**
The user requirement states: "It is very important that bridging and swapping work after deposit, since we will be investing into multiple protocols on multiple chains with each deposit."

However, the current implementation has:
- NO bridge adapters
- NO cross-chain messaging (LayerZero, Axelar, Wormhole, Hyperlane, etc.)
- NO destination chain validation
- NO bridge fee handling
- NO failed bridge recovery

**Impact:**
Protocol cannot fulfill its core requirement of multi-chain deployment.

**Recommendation:**
Implement a bridge adapter system with:
1. `IBridgeAdapter` interface
2. Concrete implementations for LayerZero, Axelar, or Wormhole
3. Bridge validation and failure recovery mechanisms
4. Cross-chain vault registry

---

### C-2: Missing VePendleAdapter and VlCvxAdapter
**Severity:** CRITICAL
**Status:** NOT IMPLEMENTED
**Location:** packages/contracts/src/adapters/

**Description:**
The README describes VePendleAdapter and VlCvxAdapter as core components, but they do not exist.

**Impact:**
- Protocol cannot lock PENDLE or CVX as documented
- Missing two of the three core yield strategies

**Recommendation:**
Implement both adapters following the IStrategyAdapter interface.

---

### C-3: Infinite Approval Vulnerability in Harvester
**Severity:** CRITICAL
**Status:** VULNERABLE
**Location:** `Harvester.sol:76, 104`

**Description:**
```solidity
usdc.safeApprove(distributor_, type(uint256).max);
```

The Harvester grants infinite approval to the Distributor. If the Distributor is compromised or has a bug, all USDC in the Harvester can be drained.

**Impact:**
Complete loss of harvested rewards if Distributor is compromised.

**Recommendation:**
Use just-in-time approvals:
```solidity
// Before transfer, approve exact amount needed
usdc.safeApprove(distributor, amount);
// After transfer, reset to 0
usdc.safeApprove(distributor, 0);
```

---

### C-4: Block.timestamp Deadline Vulnerability
**Severity:** CRITICAL
**Status:** VULNERABLE
**Location:** `UniV3RewardSwapper.sol:156, 169`, `AerodromeVeAdapter.sol:180, 192, 246, 258, 315, 330, 364, 377`

**Description:**
```solidity
deadline: block.timestamp
```

Using `block.timestamp` as deadline provides no MEV protection. Miners can hold transactions indefinitely.

**Impact:**
- Sandwi attacks
- Unfavorable execution prices
- Front-running opportunities

**Recommendation:**
```solidity
deadline: block.timestamp + MAX_DEADLINE  // e.g., 1800 (30 min)
```

---

### C-5: Unbounded Loop Gas DoS in Distributor
**Severity:** CRITICAL
**Status:** VULNERABLE
**Location:** `Distributor.sol:179-184`

**Description:**
```solidity
function claimableUSDC(address user) public view returns (uint256) {
    uint256 start = lastClaimedEpoch[user];
    uint256 end = currentEpoch;
    // ...
    for (uint256 i = start; i < end; ++i) {
        uint256 ray = epochs[i].usdcPerShareRay;
        if (ray == 0) continue;
        sumWad += (userShares * ray) / 1e27;
    }
    // ...
}
```

If a user doesn't claim for many epochs, this loop can exceed block gas limit.

**Impact:**
- Users unable to claim rewards
- claim() function becomes unusable

**Recommendation:**
1. Add max epochs per claim limit
2. Implement checkpoint-based claiming
3. Use accumulator pattern

---

### C-6: No Slippage Protection in Vault Rebalancing
**Severity:** CRITICAL
**Status:** VULNERABLE
**Location:** `PerpBondVault.sol:234-239`

**Description:**
```solidity
usdc.safeTransfer(adapter, desired);
uint256 deployedThis = IStrategyAdapter(adapter).deposit(desired);
```

No validation of minimum output from adapter.deposit(). Adapters can return 0 or fail silently.

**Impact:**
Loss of funds during rebalancing.

**Recommendation:**
```solidity
uint256 deployedThis = IStrategyAdapter(adapter).deposit(desired);
if (deployedThis < desired * MIN_DEPLOY_BPS / BPS_DENOMINATOR) {
    revert SlippageTooHigh();
}
```

---

### C-7: Missing veAERO Locking Implementation
**Severity:** CRITICAL
**Status:** NOT IMPLEMENTED
**Location:** `AerodromeVeAdapter.sol`

**Description:**
The adapter is named "AerodromeVeAdapter" and claims to lock to veAERO, but it only:
- Swaps USDC → AERO
- Holds AERO tokens
- Does NOT lock AERO to veAERO
- Does NOT vote on gauges (stub at line 286-289)
- Does NOT harvest rewards (stub at line 206-209)

**Impact:**
- No voting power acquired
- No bribes/fees earned
- Protocol cannot function as designed

**Recommendation:**
Implement actual veAERO integration:
1. Lock AERO to veAERO NFT
2. Vote on gauges via VoterRouter
3. Claim bribes, fees, and emissions
4. Properly implement harvest()

---

### C-8: Incorrect Import Paths
**Severity:** CRITICAL (Build Failure)
**Status:** BROKEN
**Location:** Multiple files

**Description:**
Many contracts have incorrect import paths:

**In `PerpBondVault.sol`:**
```solidity
import "./SafeTransferLib.sol";  // WRONG - should be "../libs/SafeTransferLib.sol"
import "./MathLib.sol";          // WRONG - should be "../libs/MathLib.sol"
import "./AdapterRegistry.sol";  // WRONG - should be "../adapters/AdapterRegistry.sol"
import "./IStrategyAdapter.sol"; // WRONG - should be "../adapters/IStrategyAdapter.sol"
```

**In `Harvester.sol`:**
```solidity
import "./AdapterRegistry.sol";  // WRONG
import "./IStrategyAdapter.sol"; // WRONG
```

**In `AerodromeVeAdapter.sol`:**
```solidity
import "./IStrategyAdapter.sol"; // WRONG - should be "./IStrategyAdapter.sol" (same dir) or "../adapters/"
import "./IVotingAdapter.sol";   // WRONG
import "./RouterGuard.sol";      // WRONG - should be "../core/RouterGuard.sol"
```

**Impact:**
- Contracts will not compile
- Cannot deploy to any network
- Build system will fail

**Recommendation:**
Fix all import paths to match actual file structure.

---

## HIGH SEVERITY ISSUES

### H-1: No Validation of Adapter Receipt
**Location:** `PerpBondVault.sol:234`
**Description:** Vault transfers USDC to adapter before calling deposit(), but doesn't validate adapter has proper access controls.
**Recommendation:** Validate adapter is registered before transfer.

### H-2: Missing Emergency Withdrawal from Vault
**Location:** `PerpBondVault.sol`
**Description:** No way to recover funds from vault in emergency.
**Recommendation:** Add emergencyWithdraw() that calls emergencyWithdraw() on all adapters.

### H-3: No Reentrancy Protection in VoterRouter
**Location:** `VoterRouter.sol:44`
**Description:** executeVotes() lacks reentrancy guard.
**Recommendation:** Add nonReentrant modifier.

### H-4: Approval Reset Pattern Inefficiency
**Location:** `Distributor.sol:205-206`
**Description:**
```solidity
usdc.safeApprove(address(vault), 0);
usdc.safeApprove(address(vault), claimed);
```
This is called on every claim with auto-compound.
**Recommendation:** Use forceApprove or maintain persistent approval.

### H-5: No Validation in SwapRewards
**Location:** `Harvester.sol:166`
**Description:** swapToUSDC can be called by any configured swapper without validation.
**Recommendation:** Add oracle validation before swaps.

### H-6: Missing Access Control on Adapter Harvest
**Location:** `AerodromeVeAdapter.sol:207`
**Description:** Allows both harvester and keeper to call harvest() but no validation.
**Recommendation:** Restrict to harvester only or add proper validation.

### H-7: Oracle Staleness Not Enforced
**Location:** `RouterGuard.sol:94-97`
**Description:** If feed aggregator is configured but staleAfter is 0, no staleness check occurs.
**Recommendation:** Require staleAfter > 0 for all feeds.

---

## MEDIUM SEVERITY ISSUES

### M-1: No Share Cap on Individual Deposits
**Location:** `PerpBondVault.sol:71`
**Description:** Single user could own 100% of shares.
**Recommendation:** Add per-user deposit caps.

### M-2: Fee BPS Not Validated on Construction
**Location:** `Distributor.sol:83`
**Description:** feeBps validated in setter but not in constructor directly.
**Recommendation:** Use _setFeeBps in constructor.

### M-3: Epoch Close Can Be Called with 0 Harvested
**Location:** `Distributor.sol:126-129`
**Description:** closeEpoch returns early but doesn't increment epoch, so keeper wastes gas.
**Recommendation:** Emit event for tracking.

### M-4: No Maximum Adapters Limit
**Location:** `AdapterRegistry.sol`
**Description:** Unlimited adapters can be registered, leading to potential gas issues in loops.
**Recommendation:** Add MAX_ADAPTERS constant.

### M-5: Missing Events in Critical Functions
**Location:** Multiple
**Description:** Some state changes don't emit events for off-chain tracking.
**Recommendation:** Add events for all state changes.

---

## LOW SEVERITY ISSUES

### L-1: Magic Numbers in Code
**Location:** Multiple
**Description:** Hardcoded values like 10_000 for BPS_DENOMINATOR appear without constants in some places.
**Recommendation:** Use constants everywhere.

### L-2: Missing NatSpec Documentation
**Location:** Multiple
**Description:** Some functions lack @param and @return tags.
**Recommendation:** Complete NatSpec for all public/external functions.

### L-3: Floating Pragma
**Location:** All contracts
**Description:** `pragma solidity ^0.8.24;` allows any 0.8.x version.
**Recommendation:** Lock to specific version for production.

### L-4: No Zero Amount Checks in Some Functions
**Location:** `AerodromeVeAdapter.sol:294, 341`
**Description:** convertIdleUSDC and sellAeroForUSDC check for 0 but after external call.
**Recommendation:** Check at function entry.

---

## RECOMMENDATIONS FOR CROSS-CHAIN IMPLEMENTATION

To fulfill the requirement of "investing into multiple protocols on multiple chains with each deposit," implement:

### 1. Bridge Adapter Interface
```solidity
interface IBridgeAdapter {
    function bridgeUSDC(
        uint256 amount,
        uint32 dstChainId,
        address dstVault,
        bytes calldata params
    ) external payable returns (bytes32 bridgeTxId);

    function estimateBridgeFee(
        uint256 amount,
        uint32 dstChainId
    ) external view returns (uint256 nativeFee);
}
```

### 2. LayerZero Bridge Adapter
Integrate with LayerZero V2 for:
- USDC bridging to destination chains
- Cross-chain messages for coordinated deposits
- Failure recovery mechanisms

### 3. Multi-Chain Vault Registry
- Track vault addresses on each supported chain
- Validate destination chains before bridging
- Coordinate allocations across chains

### 4. Enhanced Rebalancing
- Calculate optimal allocation per chain
- Execute bridge + deposit atomically
- Handle bridge delays and failures

---

## TESTING RECOMMENDATIONS

1. **Fork Tests:** Test against mainnet forks with real veAERO, vePENDLE, vlCVX
2. **Fuzzing:** Fuzz deposit/claim/rebalance with random inputs
3. **Invariant Tests:**
   - Total assets ≥ sum of user shares value
   - No inflation attacks
   - Epoch math correctness
4. **Cross-Chain Tests:** Simulate bridge failures and recovery

---

## CONCLUSION

The protocol has a solid architectural foundation but requires significant security improvements and completion of core features (especially cross-chain bridging) before deployment. The most critical issues are:

1. ⚠️ **Missing cross-chain infrastructure** (core requirement)
2. ⚠️ **Missing 2 of 3 adapters** (VePendleAdapter, VlCvxAdapter)
3. ⚠️ **Infinite approvals and deadline vulnerabilities**
4. ⚠️ **Broken import paths preventing compilation**
5. ⚠️ **Stub implementations in AerodromeVeAdapter**

**Estimated time to address:**
- Critical fixes: 3-5 days
- Missing adapters: 5-7 days
- Cross-chain implementation: 7-10 days
- Testing and validation: 3-5 days

**RECOMMENDATION:** DO NOT DEPLOY until all CRITICAL and HIGH severity issues are resolved.

---

*End of Audit Report*
