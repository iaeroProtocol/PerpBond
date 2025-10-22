Perpetual DeFi Bond — README (v0)

A USDC-in / USDC-yield protocol that allocates into veAERO, vePENDLE (lock PENDLE → vePENDLE), and vlCVX (lock CVX → vlCVX), performs weekly voting & harvesting, swaps rewards to USDC, and makes them claimable (or auto-compounded). Users receive a transferable, non-redeemable receipt token (“PerpBond”).

Note: For PENDLE and CVX we only buy the spot token and lock it (vePENDLE / vlCVX). We do not use PT/YT or LP strategies.

Monorepo Layout
perp-bond/
├─ packages/
│  ├─ contracts/                  # Foundry workspace for Solidity
│  │  ├─ src/
│  │  │  ├─ core/
│  │  │  │  ├─ PerpBondVault.sol              # ERC-4626-like USDC vault (withdraw/redeem disabled)
│  │  │  │  ├─ PerpBondToken.sol              # ERC-20 transferable receipt token (non-redeemable principal)
│  │  │  │  ├─ AdapterRegistry.sol            # Whitelist & risk caps for pluggable adapters
│  │  │  │  ├─ Harvester.sol                  # Claims rewards via adapters, swaps to USDC
│  │  │  │  ├─ Distributor.sol                # Epoch close, USDC distributions, auto-compound logic
│  │  │  │  ├─ VoterRouter.sol                # Weekly voting intents execution across protocols
│  │  │  │  ├─ AccessRoles.sol                # Governor, Guardian, Keeper, Treasury roles
│  │  │  │  └─ ErrorsEvents.sol               # Centralized custom errors & events
│  │  │  ├─ adapters/
│  │  │  │  ├─ interfaces/
│  │  │  │  │  ├─ IStrategyAdapter.sol
│  │  │  │  │  ├─ ILockingAdapter.sol         # Optional: feature flag if adapter supports locking
│  │  │  │  │  ├─ IVotingAdapter.sol          # Optional: feature flag if adapter supports voting
│  │  │  │  ├─ AerodromeVeAdapter.sol         # AERO buy+lock → veAERO; vote gauges; claim; swap→USDC
│  │  │  │  ├─ VePendleAdapter.sol            # PENDLE buy+lock → vePENDLE; vote; claim; swap→USDC
│  │  │  │  └─ VlCvxAdapter.sol               # CVX buy+lock → vlCVX; vote; claim; swap→USDC
│  │  │  ├─ libs/
│  │  │  │  ├─ RouterGuard.sol                # Whitelisted DEX routes + slippage caps
│  │  │  │  ├─ OracleLib.sol                  # Chainlink/TWAP sanity checks
│  │  │  │  ├─ SafeTransferLib.sol            # Token transfers (USDC/non-std ERC20s)
│  │  │  │  └─ MathLib.sol                    # BPS, fee accrual, checkpoint maths
│  │  │  ├─ vendor/                           # Minimal interfaces (USDC, veAERO, vePENDLE, vlCVX, etc.)
│  │  │  └─ test/
│  │  │     ├─ unit/
│  │  │     │  ├─ Vault.t.sol
│  │  │     │  ├─ Distributor.t.sol
│  │  │     │  ├─ Harvester.t.sol
│  │  │     │  ├─ AerodromeVeAdapter.t.sol
│  │  │     │  ├─ VePendleAdapter.t.sol
│  │  │     │  └─ VlCvxAdapter.t.sol
│  │  │     ├─ fork/
│  │  │     │  ├─ WeeklyCycleFork.t.sol       # Simulates deposit→lock→vote→harvest→distribute
│  │  │     └─ invariants/
│  │  │        ├─ Invariant_NavMonotonic.t.sol
│  │  │        └─ Invariant_PausesAndCaps.t.sol
│  │  ├─ script/
│  │  │  ├─ DeployCore.s.sol                  # Deploy vault, token, registry, router, harvester, distributor
│  │  │  ├─ DeployAdapters.s.sol              # Deploy & register adapters with caps & metadata
│  │  │  ├─ ConfigurePolicy.s.sol             # Set weights, oracles, slippage, fees
│  │  │  ├─ WeeklyOps.s.sol                   # Keeper entrypoints (vote/harvest/distribute)
│  │  │  └─ Migrations.s.sol
│  │  ├─ foundry.toml
│  │  └─ remappings.txt
│  │
│  ├─ sdk/                         # TypeScript SDK for FE/automation (viem)
│  │  ├─ src/
│  │  │  ├─ addresses.ts
│  │  │  ├─ abis/
│  │  │  │  ├─ PerpBondVault.json
│  │  │  │  ├─ PerpBondToken.json
│  │  │  │  ├─ AdapterRegistry.json
│  │  │  │  ├─ Harvester.json
│  │  │  │  ├─ Distributor.json
│  │  │  │  ├─ AerodromeVeAdapter.json
│  │  │  │  ├─ VePendleAdapter.json
│  │  │  │  └─ VlCvxAdapter.json
│  │  │  ├─ client.ts               # viem client factory
│  │  │  ├─ vault.ts                # deposit, claim, toggleAutocompound, epochs
│  │  │  ├─ adapters.ts             # registry discovery, tvl, apy (read funcs)
│  │  │  └─ epochs.ts               # epoch history & attribution helpers
│  │  └─ package.json
│  │
│  └─ worker/                      # Cloudflare Worker for scheduled automation (no keys on FE)
│     ├─ src/
│     │  ├─ index.ts               # scheduled() cron: call relayer webhook or Safe module
│     │  ├─ keeper.ts              # compose txs: vote(), harvest(), closeEpoch()
│     │  └─ policy.ts              # APY forecaster & target weights (read-only; writes via relayer)
│     ├─ wrangler.toml
│     └─ package.json
│
├─ apps/
│  └─ web/                         # Frontend (Next.js on Cloudflare Pages)
│     ├─ src/
│     │  ├─ app/                   # Next 14 app router (Cloudflare next-on-pages)
│     │  │  ├─ layout.tsx
│     │  │  ├─ page.tsx            # Dashboard (TVL, projected APY, allocations)
│     │  │  ├─ deposit/page.tsx    # USDC deposit → mint PerpBond
│     │  │  ├─ account/page.tsx    # Balances, claimable USDC, auto-compound toggle
│     │  │  ├─ strategy/page.tsx   # Adapters list from registry + current weights
│     │  │  ├─ epochs/page.tsx     # Epoch history, realized APY, attribution
│     │  │  └─ api/                # server actions for read-only endpoints
│     │  ├─ components/
│     │  │  ├─ DepositCard.tsx
│     │  │  ├─ ClaimCard.tsx
│     │  │  ├─ ToggleAutoCompound.tsx
│     │  │  ├─ AllocationChart.tsx
│     │  │  ├─ EpochTable.tsx
│     │  │  └─ TxModal.tsx
│     │  ├─ lib/
│     │  │  ├─ wagmiClient.ts
│     │  │  ├─ sdk.ts               # thin wrappers over packages/sdk
│     │  │  └─ format.ts
│     │  ├─ styles/globals.css
│     │  └─ env.d.ts
│     ├─ public/
│     │  └─ icons/                  # adapter icons by address
│     ├─ package.json
│     ├─ next.config.js
│     └─ functions/[[path]].ts      # (optional) edge routes for SSR on Pages
│
├─ deployments/                     # Chain-specific addresses & parameters
│  ├─ base-sepolia.json
│  └─ base.json
├─ .env.example
├─ README.md                        # (this file)
└─ LICENSE

Smart Contract Overview

PerpBondVault.sol

ERC-4626 base for shares accounting, but overrides withdraw()/redeem() to revert (no principal redemption).

Accepts USDC deposits; mints PerpBondToken.

Tracks auto-compound preference per account.

Holds allocation map adapter => targetBps (updated by Governor/Policy).

Entry points for keeper: rebalanceAllocations(), closeEpoch().

PerpBondToken.sol

ERC-20 receipt token (transferable).

No redemption; yield is separate and claimable in USDC via Distributor.

AdapterRegistry.sol

Whitelists adapters; stores caps (tvl USDC, max % of vault), slippage limits, oracle config.

Pausable per adapter; events for FE discovery.

Adapters

AerodromeVeAdapter: buys AERO, locks to veAERO, votes gauges, claims (bribes/fees/emissions) → swaps to USDC.

VePendleAdapter: buys PENDLE, locks to vePENDLE, votes, claims → swaps to USDC.

VlCvxAdapter: buys CVX, locks to vlCVX, votes, claims → swaps to USDC.

Common interface IStrategyAdapter:

deposit(uint256 usdc), harvest() returns (uint256 usdcOut), tvl(), positions(), metadata().

VoterRouter.sol

Executes weekly voting intents per adapter (gauge/weight), bounded by allowlists and caps.

Harvester.sol

Calls harvest() on each active adapter.

Uses RouterGuard to swap all rewards to USDC (per-pair slippage caps, oracle checks).

Distributor.sol

On closeEpoch(), records USDC yield for the epoch.

Claim bucket (per-user, snapshot on epoch close) vs auto-compound (re-deposit into vault and re-mint to vault, then distribute proportionally).

Optional performance fee on realized USDC yield; management fee via share inflation.

Access & Safety

Roles: Governor, Guardian, Keeper, Treasury.

Pauses: global, per-adapter, swap routes.

Oracle sanity checks, loss limits, TVL caps, ramp-rates.

Frontend Notes (Cloudflare Pages)

Framework: Next.js (App Router) + next-on-pages adapter.

Wallet: wagmi/viem.

Styling: Tailwind + shadcn/ui.

Data: read via packages/sdk; chain RPC from Cloudflare environment var.

Pages:

Dashboard: TVL, projected net APY (from SDK est.), current allocations.

Deposit: USDC approve + deposit; mint PerpBond.

Account: PerpBond balance, Claimable USDC, Auto-compound toggle.

Strategy: Live adapter list from AdapterRegistry, with caps, status, and realized contribution.

Epochs: Distribution history, realized APY, per-adapter attribution.

Cloudflare setup

Add next-on-pages and set build command:

npx @cloudflare/next-on-pages@latest

Pages → Build:

Build command: pnpm -w install && pnpm -w -r build && npx @cloudflare/next-on-pages

Output dir: .vercel/output/static (handled by adapter)

Env (Pages/Workers):

RPC_URL

CHAIN_ID

USDC_ADDRESS

(optional analytics keys)

Cache: ISR friendly; prefer on-chain reads via SDK + client caching.

Cloudflare Worker (Keeper & Policy)

We keep private keys off the frontend. Two options:

Worker → Relayer (preferred): Worker runs scheduled cron (weekly), computes target weights & bundles actions, then posts to your relayer (or Safe Transaction Service). The relayer submits on-chain txs from a Safe.

Worker signs txs (guarded): Store signer as a Cloudflare secret; use IP allowlists & simulation preflight. Recommended only with strict rate/cap guards.

wrangler.toml (excerpt):

name = "perp-bond-keeper"
main = "src/index.ts"
compatibility_date = "2025-10-01"
[triggers]
crons = ["0 0 * * 1"]   # Mondays 00:00 UTC (adjust as needed)

Configuration

.env.example

RPC_URL=

CHAIN_ID=84532 (example)

USDC_ADDRESS=0x...

TREASURY=0x...

SAFE_TX_SERVICE_URL=... (if using Safe relayer)

KEEPER_WEBHOOK=... (if posting bundle to relayer)

AERO/veAERO addresses, PENDLE/vePENDLE, CVX/vlCVX, DEX routers, Chainlink feeds.

deployments/base-sepolia.json

Network-specific addresses for vault, token, registry, adapters, router, harvester, distributor.

Development

Contracts (Foundry)

Build: forge build

Test: forge test -vvv

Fork tests: FOUNDRY_ETH_RPC_URL=$RPC_URL forge test -vv --match-path src/test/fork/*

Deploy

forge script script/DeployCore.s.sol --rpc-url $RPC_URL --broadcast

forge script script/DeployAdapters.s.sol --rpc-url $RPC_URL --broadcast

SDK

pnpm -w -F @perp-bond/sdk build

Web

pnpm -w -F web dev

Worker

pnpm -w -F @perp-bond/worker dev

wrangler deploy

Policy & Weighting

Policy module (off-chain in Worker) estimates net APY for each adapter:

Emissions + bribes + fee share − locking dilution − swap costs − perf fee.

Governor-set bounds:

Per-adapter min/max bps, TVL caps, ramp rate (bps per epoch), portfolio constraints.

Keeper proposes & executes within bounds; emits events for transparency.

Security Checklist (v0)

Reentrancy guards on vault/harvest/distribute paths.

Pausable adapters and global switches.

Strict RouterGuard (known routers/pools only; per-pair slippage).

OracleLib (Chainlink primary, TWAP fallback) for min-out sanity.

Invariants: no share inflation draining, epoch accounting soundness, paused states respected.

Gradual TVL caps; guarded mainnet rollout.

What’s “Done” for v0

USDC deposit → PerpBondToken minted.

Adapters: AerodromeVeAdapter, VePendleAdapter, VlCvxAdapter wired to buy+lock+vote+harvest.

Weekly: vote → harvest → swap to USDC → closeEpoch → claimable or auto-compound.

Frontend: deposit, account (claim/toggle), strategy, epochs.

Cloudflare: Pages for web, Worker cron for automation via relayer/Safe.
