# PerpBond Repository Structure

## Overview

PerpBond is a **monorepo** structured using **pnpm workspaces**, organizing code into reusable packages and client applications. The protocol implements a yield aggregation vault that manages USDC deposits across multiple DeFi protocol adapters (Aerodrome, Pendle, Convex).

### Organization Pattern
- **Packages**: Reusable libraries (Smart Contracts, SDK, Workers)
- **Apps**: Client applications (Web frontend)
- **Deployments**: Network-specific contract addresses

---

## Directory Structure

```
PerpBond/
├── apps/                          # Client applications
│   └── web/                       # Next.js 14 web application
├── packages/                      # Shared libraries
│   ├── contracts/                 # Foundry Solidity smart contracts
│   ├── sdk/                       # TypeScript SDK
│   └── worker/                    # Cloudflare Worker automation
├── deployments/                   # Contract deployment artifacts
├── README.md                      # Main project documentation
├── SECURITY_AUDIT_REPORT.md       # Security audit findings
├── IMPROVEMENTS_SUMMARY.md        # Audit improvements summary
├── SmartContractBuildOutPlan.pdf  # Architecture & design document
└── .gitignore                     # Git ignore patterns
```

---

## Applications (`/apps`)

### Web Application (`/apps/web`)

Next.js 14 web frontend deployed on Cloudflare Pages.

```
apps/web/
├── src/
│   ├── app/                       # Next.js App Router (pages & API routes)
│   │   ├── page.tsx              # Dashboard (TVL, APY, allocations)
│   │   ├── layout.tsx            # Root layout with providers
│   │   ├── deposit/              # USDC deposit interface
│   │   ├── account/              # User balances & claims
│   │   ├── strategy/             # Adapter list & weights
│   │   ├── epochs/               # Epoch history & realized APY
│   │   └── api/                  # Server actions (read-only)
│   ├── components/               # React components
│   │   ├── PerpBondApp.tsx       # Main app component
│   │   ├── Connect.tsx           # Wallet connection logic
│   │   ├── ConnectPanel.tsx      # Wallet UI panel
│   │   ├── DepositCard.tsx       # Deposit form
│   │   ├── ClaimCard.tsx         # Claim rewards
│   │   └── ToggleAutoCompound.tsx # Auto-compound toggle
│   ├── lib/                      # Utilities & SDK wrappers
│   │   ├── wagmiClient.ts        # Wagmi/Viem configuration
│   │   ├── sdk.ts                # SDK wrapper functions
│   │   └── format.ts             # Data formatting utilities
│   ├── styles/
│   │   └── globals.css           # Global Tailwind/CSS styles
│   ├── tasks/
│   │   └── perpbond.ts           # Hardhat tasks
│   └── public/
│       └── icons/                # Adapter icons by address
├── package.json                  # Web app dependencies
├── tsconfig.json                 # TypeScript configuration
├── next.config.js                # Next.js configuration
├── tailwind.config.ts            # Tailwind CSS configuration
├── hardhat.config.ts             # Hardhat configuration
└── README.md                     # Web app documentation
```

**Tech Stack:**
- Next.js 14 (App Router)
- TypeScript
- Wagmi + Viem (wallet integration)
- Tailwind CSS (styling)
- Cloudflare Pages (deployment)

---

## Packages (`/packages`)

### Smart Contracts (`/packages/contracts`)

Foundry-based Solidity smart contracts implementing the PerpBond protocol.

```
packages/contracts/
├── src/
│   ├── core/                      # Core protocol contracts
│   │   ├── PerpBondVault.sol      # ERC-4626 USDC vault (no withdrawals)
│   │   ├── PerpBondToken.sol      # ERC-20 receipt token (transferable)
│   │   ├── AdapterRegistry.sol    # Whitelist & risk management
│   │   ├── Harvester.sol          # Reward harvesting & swap logic
│   │   ├── Distributor.sol        # Epoch close & yield distribution
│   │   ├── VoterRouter.sol        # Weekly voting execution
│   │   ├── RouterGuard.sol        # DEX route & slippage guards
│   │   ├── UniV3RewardSwapper.sol # Uniswap V3 swap integration
│   │   ├── AccessRoles.sol        # RBAC (Governor, Guardian, Keeper)
│   │   └── ErrorsEvents.sol       # Centralized errors & events
│   ├── adapters/                  # Protocol integrations
│   │   ├── AerodromeVeAdapter.sol # AERO → veAERO strategy
│   │   ├── VePendleAdapter.sol    # PENDLE → vePENDLE strategy
│   │   ├── VlCvxAdapter.sol       # CVX → vlCVX strategy
│   │   ├── IStrategyAdapter.sol   # Base strategy interface
│   │   ├── ILockingAdapter.sol    # Locking feature interface
│   │   ├── IVotingAdapter.sol     # Voting feature interface
│   │   ├── IBridgeAdapter.sol     # Bridge adapter interface
│   │   └── LayerZeroBridgeAdapter.sol # LayerZero integration
│   ├── libs/                      # Utility libraries
│   │   ├── MathLib.sol            # BPS, fee accrual, checkpoint math
│   │   ├── OracleLib.sol          # Chainlink/TWAP oracle integration
│   │   └── SafeTransferLib.sol    # Safe ERC20 transfers
│   ├── vendor/                    # External interface stubs
│   └── test/                      # Test suite
│       ├── unit/                  # Unit tests
│       │   ├── Vault.t.sol
│       │   ├── Distributor.t.sol
│       │   ├── Harvester.t.sol
│       │   ├── AerodromeVeAdapter.t.sol
│       │   ├── VePendleAdapter.t.sol
│       │   └── VlCvxAdapter.t.sol
│       ├── fork/                  # Fork tests
│       │   └── WeeklyCycleFork.t.sol
│       └── invariants/            # Invariant tests
│           ├── Invariant_NavMonotonic.t.sol
│           └── Invariant_PausesAndCaps.t.sol
├── script/                        # Deployment & operation scripts
│   ├── ConfigurePerpBondBase.s.sol # Base configuration
│   ├── configureBase.ts           # TypeScript configuration helper
│   ├── DeployCore.s.sol           # Deploy core contracts
│   ├── DeployAdapters.s.sol       # Deploy & register adapters
│   ├── ConfigurePolicy.s.sol      # Set weights & parameters
│   ├── WeeklyOps.s.sol            # Keeper operations
│   └── Migrations.s.sol           # Migration scripts
├── lib/                           # Foundry dependencies
├── foundry.toml                   # Foundry configuration
└── remappings.txt                 # Solidity import remappings
```

**Key Components:**

#### Core Contracts
- **PerpBondVault**: Main ERC-4626 vault accepting USDC deposits (withdrawals disabled)
- **PerpBondToken**: ERC-20 receipt token (fully transferable)
- **AdapterRegistry**: Manages whitelisted adapters with risk parameters
- **Harvester**: Collects rewards from adapters and swaps to USDC
- **Distributor**: Handles epoch closing and yield distribution
- **VoterRouter**: Executes weekly voting strategies across protocols

#### Adapters
- **AerodromeVeAdapter**: AERO → veAERO locking and voting
- **VePendleAdapter**: PENDLE → vePENDLE locking and voting
- **VlCvxAdapter**: CVX → vlCVX vote-locking
- **LayerZeroBridgeAdapter**: Cross-chain bridge integration

#### Libraries & Guards
- **MathLib**: BPS calculations, fee accrual, checkpoint math
- **OracleLib**: Chainlink/TWAP oracle integration
- **RouterGuard**: DEX routing validation and slippage protection

**Tech Stack:**
- Foundry (Solidity development framework)
- OpenZeppelin (ERC standards & security)
- Solidity 0.8.x

---

### SDK (`/packages/sdk`)

TypeScript SDK for frontend and off-chain automation.

```
packages/sdk/
├── src/
│   ├── addresses.ts               # Network-specific contract addresses
│   ├── client.ts                  # Viem client factory
│   ├── vault.ts                   # Vault operations
│   ├── registry.ts                # Adapter registry queries
│   ├── distributor.ts             # Distributor interactions
│   ├── index.ts                   # SDK exports
│   └── abis/                      # Contract ABIs (generated)
│       ├── vault.ts               # PerpBondVault ABI
│       ├── distributor.ts         # Distributor ABI
│       ├── registry.ts            # AdapterRegistry ABI
│       └── erc20.ts               # ERC20 ABI
├── dist/                          # Compiled output
├── package.json                   # SDK dependencies
└── tsconfig.json                  # TypeScript configuration
```

**Features:**
- Contract interaction wrappers (deposit, claim, auto-compound)
- Multi-network support (Base, Base Sepolia)
- Type-safe ABI interfaces
- Viem-based client factory

**Tech Stack:**
- TypeScript
- Viem (Ethereum library)
- ABIType (type-safe ABIs)

---

### Worker (`/packages/worker`)

Cloudflare Worker for serverless keeper automation.

```
packages/worker/
├── src/
│   ├── index.ts                   # Scheduled cron entry point
│   ├── keeper.ts                  # Transaction composition logic
│   └── policy.ts                  # APY forecasting & weight calculation
├── wrangler.toml                  # Cloudflare Worker config
└── package.json                   # Worker dependencies
```

**Purpose:**
- Automated weekly keeper operations (harvest, vote, distribute)
- APY forecasting and weight calculation
- Transaction bundling and execution
- Scheduled via Cloudflare cron triggers

**Tech Stack:**
- Cloudflare Workers (serverless runtime)
- TypeScript
- Wrangler CLI

---

## Deployments (`/deployments`)

Network-specific deployment artifacts containing contract addresses.

```
deployments/
├── base-sepolia.json              # Base Sepolia testnet addresses
└── base.json                      # Base mainnet addresses
```

**Contents:**
- Core contract addresses
- Adapter addresses
- Token addresses
- Deployment metadata

---

## Documentation Files

### Root Level Documentation

| File | Purpose |
|------|---------|
| `README.md` | Complete project overview, architecture, and setup instructions |
| `REPO_STRUCTURE.md` | This file - repository structure documentation |
| `SECURITY_AUDIT_REPORT.md` | Security audit findings and recommendations |
| `IMPROVEMENTS_SUMMARY.md` | Summary of security improvements implemented |
| `SmartContractBuildOutPlan.pdf` | Detailed architecture and protocol design document |
| `.gitignore` | Git ignore patterns (Foundry, Node, IDE, keys, build outputs) |

---

## Technology Stack Summary

| Component | Framework | Language | Key Libraries |
|-----------|-----------|----------|---------------|
| **Smart Contracts** | Foundry | Solidity | OpenZeppelin, ERC-4626 |
| **Frontend** | Next.js 14 | TypeScript/React | Wagmi, Viem, Tailwind |
| **SDK** | Viem | TypeScript | ABIType |
| **Automation** | Cloudflare Workers | TypeScript | Wrangler |

---

## Development Workflow

### Smart Contracts
```bash
cd packages/contracts
forge build                        # Compile contracts
forge test                         # Run tests
forge script script/Deploy.s.sol   # Deploy contracts
```

### Web Application
```bash
cd apps/web
npm install                        # Install dependencies
npm run dev                        # Start development server
npm run build                      # Build for production
```

### SDK
```bash
cd packages/sdk
npm install                        # Install dependencies
npm run build                      # Compile TypeScript
```

### Worker
```bash
cd packages/worker
npm install                        # Install dependencies
npx wrangler dev                   # Test locally
npx wrangler deploy                # Deploy to Cloudflare
```

---

## Architecture Principles

### 1. Monorepo Benefits
- **Code Sharing**: SDK used by both web app and worker
- **Type Safety**: Shared TypeScript types across packages
- **Atomic Changes**: Update contracts, SDK, and frontend together

### 2. Separation of Concerns
- **Core**: Business logic and protocol mechanics
- **Adapters**: Pluggable protocol integrations
- **Frontend**: User-facing application
- **Automation**: Background keeper operations

### 3. Security-First
- Comprehensive test coverage (unit, fork, invariant)
- External security audit conducted
- Role-based access control (Governor, Guardian, Keeper)
- Immutable deployment patterns

### 4. Scalability
- Cross-chain ready (LayerZero integration)
- Pluggable adapter architecture
- Serverless automation (Cloudflare Workers)
- Multi-protocol support (Aerodrome, Pendle, Convex)

---

## Key Configuration Files

### Root Level
- `.gitignore` - Git ignore patterns
- `.env.example` - Environment variables template (if exists)

### Contracts
- `foundry.toml` - Foundry configuration (compiler, optimizer, RPC)
- `remappings.txt` - Solidity import remappings

### Web App
- `next.config.js` - Next.js configuration
- `tailwind.config.ts` - Tailwind CSS configuration
- `tsconfig.json` - TypeScript configuration
- `hardhat.config.ts` - Hardhat configuration (for tasks)

### Worker
- `wrangler.toml` - Cloudflare Worker configuration (cron schedule, env vars)

---

## Important Notes

1. **No Root Package.json**: This is a pnpm-driven monorepo; each workspace manages its own dependencies independently.

2. **Test-Driven Development**: Contracts include comprehensive tests (unit, fork, invariants) reflecting security-first development practices.

3. **Deployment-Ready**: Includes scripts for all deployment stages (deploy core, adapters, configure, weekly ops).

4. **Cross-Chain Capable**: LayerZero bridge adapter suggests multi-chain expansion capability.

5. **Governance Structure**: Clear role-based access control separates concerns:
   - **Governor**: Protocol upgrades and policy changes
   - **Guardian**: Emergency pause capabilities
   - **Keeper**: Automated weekly operations
   - **Treasury**: Fee collection

---

## Getting Started

### Prerequisites
- Node.js 18+
- pnpm
- Foundry (for contracts)
- Wrangler CLI (for worker)

### Quick Start
```bash
# Clone repository
git clone https://github.com/iaeroProtocol/PerpBond.git
cd PerpBond

# Install dependencies (each package separately)
cd packages/contracts && forge install && cd ../..
cd apps/web && npm install && cd ../..
cd packages/sdk && npm install && cd ../..
cd packages/worker && npm install && cd ../..

# Run tests
cd packages/contracts && forge test

# Start web app
cd apps/web && npm run dev
```

---

## Related Documentation

- [Main README](./README.md) - Project overview and architecture
- [Security Audit Report](./SECURITY_AUDIT_REPORT.md) - Security findings and mitigations
- [Improvements Summary](./IMPROVEMENTS_SUMMARY.md) - Audit-driven improvements
- [Smart Contract Build Out Plan](./SmartContractBuildOutPlan.pdf) - Detailed design document
- [Web App README](./apps/web/README.md) - Frontend-specific documentation

---

**Last Updated**: 2025-10-22
