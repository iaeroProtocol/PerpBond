## PerpBond — Dev Quickstart (Base / Base‑Sepolia)

### 1) Prereqs
- Node 18+ / pnpm or npm
- Foundry **or** Hardhat
- A funded deployer for the target network (Base or Base‑Sepolia)

### 2) Install & run the frontend
```bash
pnpm install   # or: npm install
cp .env.sample .env.local
# set NEXT_PUBLIC_* to your target network (Base Sepolia by default)
pnpm dev       # or: npm run dev

