import { parseUnits, formatUnits, type Address } from "viem";
import { addresses } from "./addresses";
import { erc20Abi } from "./abis/erc20";
import { vaultAbi } from "./abis/vault";

export type Overview = {
  tvl: number;
  apy: number; // decimal, e.g., 0.12 = 12%
  allocations: { name: string; bps: number }[];
};

export async function getOverview(pub: any, chainId: number): Promise<Overview> {
  const a = addresses[chainId];
  if (!a) return { tvl: 0, apy: 0, allocations: [] };

  const [assets, supply] = await Promise.all([
    pub.readContract({ address: a.vault, abi: vaultAbi, functionName: "totalAssets" }),
    pub.readContract({ address: a.vault, abi: vaultAbi, functionName: "totalSupply" }),
  ]);

  // NOTE: apy & allocations are placeholders until policy endpoints exist
  return {
    tvl: Number(formatUnits(assets, 6)), // USDC 6dp
    apy: 0,
    allocations: [
      { name: "veAERO", bps: 3333 },
      { name: "vePENDLE", bps: 3333 },
      { name: "vlCVX", bps: 3334 },
    ],
  };
}

export async function getAutoCompound(pub: any, chainId: number, user: Address) {
  const a = addresses[chainId]; if (!a) return false;
  return pub.readContract({ address: a.vault, abi: vaultAbi, functionName: "autoCompoundOf", args: [user] }) as Promise<boolean>;
}

export async function setAutoCompound(wallet: any, chainId: number, on: boolean) {
  const a = addresses[chainId]; if (!a) throw new Error("no addresses");
  return wallet.writeContract({ address: a.vault, abi: vaultAbi, functionName: "setAutoCompound", args: [on] });
}

export async function depositUSDC(wallet: any, pub: any, chainId: number, user: Address, amountStr: string) {
  const a = addresses[chainId]; if (!a) throw new Error("no addresses");
  const amt = parseUnits(amountStr, 6);

  const [allow] = await Promise.all([
    pub.readContract({ address: a.usdc, abi: erc20Abi, functionName: "allowance", args: [user, a.vault] }),
  ]);
  if (allow < amt) {
    await wallet.writeContract({ address: a.usdc, abi: erc20Abi, functionName: "approve", args: [a.vault, amt] });
  }
  return wallet.writeContract({ address: a.vault, abi: vaultAbi, functionName: "deposit", args: [amt, user] });
}

