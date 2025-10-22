import { ethers } from "hardhat";

function encodePath(tokens: string[], fees: number[]): string {
  if (tokens.length !== fees.length + 1) throw new Error("bad path");
  // Build packed: token0, fee0, token1, fee1, ..., tokenN
  let packed = "0x";
  for (let i = 0; i < fees.length; i++) {
    packed += ethers.getAddress(tokens[i]).slice(2);
    packed += ethers.zeroPadValue(ethers.toBeHex(fees[i], 3), 3).slice(2); // uint24
  }
  packed += ethers.getAddress(tokens[tokens.length - 1]).slice(2);
  return packed;
}

async function main() {
  const [
    GOVERNOR, // signer 0 by default
  ] = await ethers.getSigners();

  // ----- Fill from env or deployment artefacts -----
  const USDC  = process.env.USDC!;
  const WETH  = process.env.WETH!;
  const AERO  = process.env.AERO!;
  const UNI_V3_ROUTER = process.env.UNIV3_ROUTER!;

  const REGISTRY   = process.env.REGISTRY!;
  const VAULT      = process.env.VAULT!;
  const ROUTER_GUARD = process.env.ROUTER_GUARD!;
  const HARVESTER  = process.env.HARVESTER!;
  const DISTRIBUTOR = process.env.DISTRIBUTOR!;
  const AERO_ADAPTER = process.env.AERO_ADAPTER!;

  const MAX_SLIP_USDC_AERO = Number(process.env.MAX_SLIP_USDC_AERO ?? 100);
  const MAX_SLIP_AERO_USDC = Number(process.env.MAX_SLIP_AERO_USDC ?? 100);
  const DIST_FEE_BPS       = Number(process.env.DIST_FEE_BPS ?? 1000);

  const FEE_USDC_WETH = Number(process.env.FEE_USDC_WETH ?? 500);
  const FEE_WETH_AERO = Number(process.env.FEE_WETH_AERO ?? 3000);
  const FEE_AERO_WETH = Number(process.env.FEE_AERO_WETH ?? 3000);
  const FEE_WETH_USDC = Number(process.env.FEE_WETH_USDC ?? 500);

  // Optional feeds
  const FEED_USDC = process.env.FEED_USDC;
  const FEED_WETH = process.env.FEED_WETH;
  const FEED_AERO = process.env.FEED_AERO;
  const STALE     = Number(process.env.FEED_STALE_AFTER ?? 3600);
  const DEC_USDC  = Number(process.env.DEC_USDC ?? 6);
  const DEC_WETH  = Number(process.env.DEC_WETH ?? 18);
  const DEC_AERO  = Number(process.env.DEC_AERO ?? 18);

  const registry   = await ethers.getContractAt("AdapterRegistry", REGISTRY, GOVERNOR);
  const vault      = await ethers.getContractAt("PerpBondVault", VAULT, GOVERNOR);
  const guard      = await ethers.getContractAt("RouterGuard", ROUTER_GUARD, GOVERNOR);
  const harvester  = await ethers.getContractAt("Harvester", HARVESTER, GOVERNOR);
  const distributor= await ethers.getContractAt("Distributor", DISTRIBUTOR, GOVERNOR);
  const adapter    = await ethers.getContractAt("AerodromeVeAdapter", AERO_ADAPTER, GOVERNOR);

  // 1) Guard
  await (await guard.setRouterAllowed(UNI_V3_ROUTER, true)).wait();
  await (await guard.setMaxSlippageBps(USDC, AERO, MAX_SLIP_USDC_AERO)).wait();
  await (await guard.setMaxSlippageBps(AERO, USDC, MAX_SLIP_AERO_USDC)).wait();

  if (FEED_USDC) await (await guard.setFeed(USDC, FEED_USDC, STALE, DEC_USDC)).wait();
  if (FEED_WETH) await (await guard.setFeed(WETH, FEED_WETH, STALE, DEC_WETH)).wait();
  if (FEED_AERO) await (await guard.setFeed(AERO, FEED_AERO, STALE, DEC_AERO)).wait();

  // 2) Registry (register or update)
  const info = {
    active: true,
    adapter: AERO_ADAPTER,
    tvlCapUSDC: 0n,
    maxBpsOfVault: 10000,
    maxSlippageBpsOnSwap: 150,
    oracleConfig: "0x",
  };

  try {
    await (await registry.updateAdapter(info)).wait();
  } catch {
    await (await registry.registerAdapter(info)).wait();
  }
  await (await registry.setAdapterActive(AERO_ADAPTER, true)).wait();

  // 3) Vault allocation: 100% to this adapter
  await (await vault.setTargetAllocations([AERO_ADAPTER], [10000])).wait();

  // 4) Adapter routes + guard + router
  await (await adapter.setRouter(UNI_V3_ROUTER)).wait();
  await (await adapter.setGuard(ROUTER_GUARD)).wait();

  const pathUSDCtoAERO = encodePath([USDC, WETH, AERO], [FEE_USDC_WETH, FEE_WETH_AERO]);
  const pathAEROtoUSDC = encodePath([AERO, WETH, USDC], [FEE_AERO_WETH, FEE_WETH_USDC]);

  await (await adapter.setDepositRoute(pathUSDCtoAERO, 0)).wait();
  await (await adapter.setExitRoute(pathAEROtoUSDC, 0)).wait();

  // 5) Harvester ⇄ Distributor, fee
  await (await harvester.setDistributor(DISTRIBUTOR)).wait();
  await (await distributor.setHarvester(HARVESTER)).wait();
  await (await distributor.setFeeBps(DIST_FEE_BPS)).wait();

  console.log("Configuration complete.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
