import { formatUnits } from "viem";
import { addresses } from "./addresses";
import { distributorAbi } from "./abis/distributor";
import type { Address } from "viem";

export async function getClaimableUSDC(pub: any, chainId: number, user: Address): Promise<string> {
  const a = addresses[chainId]; if (!a) return "0.00";
  const raw = await pub.readContract({ address: a.distributor, abi: distributorAbi, functionName: "claimableUSDC", args: [user] });
  return Number(formatUnits(raw, 6)).toFixed(2);
}

export async function claimUSDC(wallet: any, chainId: number) {
  const a = addresses[chainId]; if (!a) throw new Error("no addresses");
  return wallet.writeContract({ address: a.distributor, abi: distributorAbi, functionName: "claim", args: [] });
}

