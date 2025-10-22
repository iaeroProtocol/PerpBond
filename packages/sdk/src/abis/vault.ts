export const vaultAbi = [
  // ERC4626 subset
  { type: 'function', name: 'deposit',  stateMutability: 'nonpayable', inputs: [{ name: 'assets', type: 'uint256' }, { name: 'receiver', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalAssets', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'balanceOf',   stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },

  // Custom
  { type: 'function', name: 'autoCompoundOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'setAutoCompound', stateMutability: 'nonpayable', inputs: [{ type: 'bool' }], outputs: [] },

  // Read-only helper (optional; else compute from registry):
  { type: 'function', name: 'targetAllocBps', stateMutability: 'view', inputs: [{ type: 'address' /* adapter */ }], outputs: [{ type: 'uint16' }] },
] as const;

