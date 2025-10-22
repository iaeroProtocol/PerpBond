export type ChainId = 8453 | 84532 | number; // Base / Base Sepolia (default types)

export type Contracts = {
  usdc: `0x${string}`;
  vault: `0x${string}`;
  distributor: `0x${string}`;
  registry: `0x${string}`;
};

export const addresses: Record<ChainId, Contracts> = {
  // TODO: fill these once deployed
  84532: {
    usdc:       '0x0000000000000000000000000000000000000000',
    vault:      '0x0000000000000000000000000000000000000000',
    distributor:'0x0000000000000000000000000000000000000000',
    registry:   '0x0000000000000000000000000000000000000000',
  },
  8453: {
    usdc:       '0x0000000000000000000000000000000000000000',
    vault:      '0x0000000000000000000000000000000000000000',
    distributor:'0x0000000000000000000000000000000000000000',
    registry:   '0x0000000000000000000000000000000000000000',
  }
};

