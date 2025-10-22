export const distributorAbi = [
  { type: 'function', name: 'claimableUSDC', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'claim', stateMutability: 'nonpayable', inputs: [], outputs: [] },

  // Epoch views (optional; else index via logs)
  { type: 'function', name: 'epochCount', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'epochs', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [
    { name: 'id', type: 'uint256' }, { name: 'timestamp', type: 'uint256' }, { name: 'usdc', type: 'uint256' }, { name: 'apyBps', type: 'uint16' }
  ]},
] as const;

