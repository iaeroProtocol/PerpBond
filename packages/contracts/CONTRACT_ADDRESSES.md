# PerpBond Protocol Contract Addresses

## LayerZero V2 Endpoints

All chains use the same LayerZero V2 Endpoint address:

**LayerZero EndpointV2**: `0x1a44076050125825900e736c501f859c50fE728c`

Supported on:
- Ethereum Mainnet
- Base Mainnet
- Arbitrum One
- Optimism Mainnet
- Polygon PoS
- And all other EVM chains supported by LayerZero V2

## Aerodrome Finance (Base Mainnet)

The AerodromeVeAdapter integrates with these contracts on Base:

| Contract | Address | Purpose |
|----------|---------|---------|
| AERO Token | `0x940181a94A35A4569E4529A3CDfB74e38FD98631` | Native token for Aerodrome |
| VotingEscrow (veAERO) | `0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4` | Lock AERO → receive veAERO NFT for voting |
| Voter | `0x16613524e02ad97eDfeF371bC883F2F5d6C480A5` | Gauge voting contract |
| RewardsDistributor | `0x227f65131A261548b057215bB1D5Ab2997964C7d` | Rebase rewards distribution |

### Integration Details

- **veAERO** uses NFT-based voting escrow (each lock = 1 ERC-721 NFT)
- **Lock Duration**: 1 week to 4 years (default: 1 year)
- **Voting Power**: Linear increase with lock duration
- **Rewards**: Rebase rewards + voting bribes + protocol fees

## Pendle Finance (Ethereum Mainnet)

The VePendleAdapter integrates with these contracts on Ethereum:

| Contract | Address | Purpose |
|----------|---------|---------|
| PENDLE Token | `0x808507121B80c02388fAd14726482e061B8da827` | Native token for Pendle |
| vePENDLE | `0x4f30A9d41B80ecC5B94306AB4364951AE3170210` | VotingEscrowPendleMainchain |

### Integration Details

- **Lock Duration**: 1 week to 2 years (104 weeks max)
- **Rewards**: vePENDLE emissions + gauges bribes + protocol fees
- **Voting**: Pendle uses gauge voting for pool incentives

## Convex Finance (Ethereum Mainnet)

The VlCvxAdapter integrates with these contracts on Ethereum:

| Contract | Address | Purpose |
|----------|---------|---------|
| CVX Token | `0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B` | Convex governance token |
| CvxLockerV2 (vlCVX) | `0x72a19342e8F1838460eBFCCEf09F6585e32db86E` | Vote-locking contract (V2) |
| cvxCRV Rewards | `0x3Fe65692bfCD0e6CF84cB1E7d24108E434A7587e` | cvxCRV rewards pool |

### Integration Details

- **Lock Duration**: Fixed 16-week epochs
- **Relocking**: Can automatically relock on expiry to maintain voting power
- **Rewards**: cvxCRV emissions + platform fees + voting bribes
- **Voting**: On-chain gauge votes or Snapshot voting

## Deployment Checklist

When deploying PerpBond adapters, ensure:

### AerodromeVeAdapter (Base)
1. ✅ Set swap router (Uniswap V3 on Base)
2. ✅ Configure deposit/exit routes (USDC↔AERO)
3. ✅ Set Aerodrome contracts via `setAerodromeContracts()`
4. ✅ Set RouterGuard for oracle slippage protection
5. ✅ Configure lock duration (default: 365 days)
6. ✅ Register adapter in AdapterRegistry with appropriate TVL caps

### VePendleAdapter (Ethereum)
1. Set swap router (Uniswap V3)
2. Set Pendle contracts via `setPendleContracts()`
3. Configure lock duration (52-104 weeks)
4. Register adapter with caps

### VlCvxAdapter (Ethereum)
1. Set swap router (Uniswap V3 or Curve)
2. Set Convex contracts via `setConvexContracts()`
3. Configure periodic relock keeper job (every ~15 weeks)
4. Register adapter with caps

### LayerZeroBridgeAdapter (All chains)
1. ✅ Set LayerZero Endpoint V2: `0x1a44076050125825900e736c501f859c50fE728c`
2. Configure supported chain IDs and trusted remotes
3. Set default gas limit (200,000 recommended)
4. Fund adapter with native tokens for bridge fees

## Security Notes

- All adapters inherit `AccessRoles` for multi-role governance
- Emergency pause available via Guardian role
- Oracle-based slippage protection via RouterGuard
- ReentrancyGuard on all state-changing functions
- No infinite token approvals (reset to 0 before approve)
- LayerZero V2 uses trusted remotes for cross-chain security

## Resources

- [Aerodrome Docs](https://docs.aerodrome.finance/)
- [Pendle Docs](https://docs.pendle.finance/)
- [Convex Docs](https://docs.convexfinance.com/)
- [LayerZero V2 Docs](https://docs.layerzero.network/v2)
