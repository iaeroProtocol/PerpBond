import { createPublicClient, createWalletClient, http, type Account, type Transport } from "viem";

export function makePublicClient(rpcUrl: string, chain: { id: number; name?: string }) {
  return createPublicClient({ transport: http(rpcUrl), chain });
}

export function makeWalletClient(rpcUrl: string, chain: { id: number }, account: Account) {
  return createWalletClient({ transport: http(rpcUrl) as Transport, chain, account });
}

