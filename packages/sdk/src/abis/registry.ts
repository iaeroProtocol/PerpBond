export const registryAbi = [
  { type: 'function', name: 'list', stateMutability: 'view', inputs: [], outputs: [
    { type: 'tuple[]', components: [
      { name: 'active', type: 'bool' },
      { name: 'adapter', type: 'address' },
      { name: 'tvlCapUSDC', type: 'uint256' },
      { name: 'maxBpsOfVault', type: 'uint16' },
      { name: 'maxSlippageBpsOnSwap', type: 'uint16' },
      { name: 'oracleConfig', type: 'bytes' }
    ]}
  ]},
] as const;

