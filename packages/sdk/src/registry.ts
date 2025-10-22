import { addresses } from "./addresses";
import { registryAbi } from "./abis/registry";

export type AdapterRow = { name: string; cap: number; active: boolean; tvl: number; apy: number; adapter: `0x${string}` };

export async function getAdapters(pub: any, chainId: number): Promise<AdapterRow[]> {
  const a = addresses[chainId]; if (!a) return [];
  const res = await pub.readContract({ address: a.registry, abi: registryAbi, functionName: "list" }) as any[];

  // Name/APY/TVL are placeholders until adapters expose metadata & tvl()
  return res.map((info: any) => ({
    name: guessName(info.adapter),
    cap: Number(info.tvlCapUSDC) / 1e6,
    active: info.active,
    tvl: 0,
    apy: 0,
    adapter: info.adapter,
  }));
}

function guessName(addr: string) {
  // optional address map → label
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

