// tasks/perpbond.ts
import { task } from "hardhat/config";
import { ethers } from "hardhat";

// --- helpers ---
function parseCsv<T extends string | number>(csv: string, map: (s: string) => T): T[] {
  return csv.split(",").map((s) => map(s.trim()));
}
function encodePath(tokensCsv: string, feesCsv: string) {
  const tokens = parseCsv(tokensCsv, (s) => ethers.getAddress(s));
  const fees = parseCsv(feesCsv, (s) => Number(s));
  if (tokens.length !== fees.length + 1) throw new Error("Path shape: tokens=N, fees=N-1");
  let out = "0x";
  for (let i = 0; i < fees.length; i++) {
    out += tokens[i].slice(2);
    out += ethers.zeroPadValue(ethers.toBeHex(fees[i], 3), 3).slice(2); // uint24
  }
  out += tokens[tokens.length - 1].slice(2);
  return out;
}

// perpbond:set-routes
task("perpbond:set-routes", "Set adapter router/guard and deposit/exit routes")
  .addParam("adapter")
  .addOptionalParam("router")
  .addOptionalParam("guard")
  .addOptionalParam("depositTokens", "CSV: tokenA,tokenB,...")
  .addOptionalParam("depositFees", "CSV: feeAB,feeBC,...")
  .addOptionalParam("depositFee", "uint24 single pool")
  .addOptionalParam("exitTokens", "CSV: tokenA,tokenB,...")
  .addOptionalParam("exitFees", "CSV: feeAB,feeBC,...")
  .addOptionalParam("exitFee", "uint24 single pool")
  .setAction(async (args, hre) => {
    const [signer] = await hre.ethers.getSigners();
    const adapter = await hre.ethers.getContractAt("AerodromeVeAdapter", args.adapter, signer);

    if (args.router) await (await adapter.setRouter(args.router)).wait();
    if (args.guard) await (await adapter.setGuard(args.guard)).wait();

    if (args.depositTokens && args.depositFees) {
      const path = encodePath(args.depositTokens, args.depositFees);
      await (await adapter.setDepositRoute(path, 0)).wait();
      console.log("deposit path set");
    } else if (args.depositFee) {
      await (await adapter.setDepositRoute("0x", Number(args.depositFee))).wait();
      console.log("deposit single-pool fee set");
    }

    if (args.exitTokens && args.exitFees) {
      const path = encodePath(args.exitTokens, args.exitFees);
      await (await adapter.setExitRoute(path, 0)).wait();
      console.log("exit path set");
    } else if (args.exitFee) {
      await (await adapter.setExitRoute("0x", Number(args.exitFee))).wait();
      console.log("exit single-pool fee set");
    }
    console.log("done.");
  });

// perpbond:set-feeds
task("perpbond:set-feeds", "Set Chainlink feeds in RouterGuard")
  .addParam("guard")
  .addParam("token")
  .addParam("aggregator")
  .addParam("staleAfter", "seconds")
  .addParam("tokenDecimals", "e.g., 6 for USDC, 18 for WETH")
  .setAction(async (a, hre) => {
    const [signer] = await hre.ethers.getSigners();
    const guard = await hre.ethers.getContractAt("RouterGuard", a.guard, signer);
    await (await guard.setFeed(a.token, a.aggregator, Number(a.staleAfter), Number(a.tokenDecimals))).wait();
    console.log("feed set");
  });

// perpbond:set-slippage
task("perpbond:set-slippage", "Whitelist router + set slippage for tokenIn->tokenOut")
  .addParam("guard")
  .addParam("router")
  .addParam("allow", "true|false")
  .addParam("tokenIn")
  .addParam("tokenOut")
  .addParam("bps", "max slippage (0..10000)")
  .setAction(async (a, hre) => {
    const [signer] = await hre.ethers.getSigners();
    const guard = await hre.ethers.getContractAt("RouterGuard", a.guard, signer);
    await (await guard.setRouterAllowed(a.router, a.allow === "true")).wait();
    await (await guard.setMaxSlippageBps(a.tokenIn, a.tokenOut, Number(a.bps))).wait();
    console.log("router + slippage updated");
  });

// perpbond:register-adapter
task("perpbond:register-adapter", "Register or update adapter in AdapterRegistry")
  .addParam("registry")
  .addParam("adapter")
  .addOptionalParam("active", "true|false", "true")
  .addOptionalParam("cap", "tvl cap in USDC (uint)", "0")
  .addOptionalParam("maxBps", "max % of vault (0..10000)", "10000")
  .addOptionalParam("slippageBps", "max swap slippage (0..10000)", "150")
  .addOptionalParam("oracleConfig", "hex bytes", "0x")
  .setAction(async (a, hre) => {
    const [signer] = await hre.ethers.getSigners();
    const reg = await hre.ethers.getContractAt("AdapterRegistry", a.registry, signer);

    const info = {
      active: a.active === "true",
      adapter: a.adapter,
      tvlCapUSDC: BigInt(a.cap),
      maxBpsOfVault: Number(a.maxBps),
      maxSlippageBpsOnSwap: Number(a.slippageBps),
      oracleConfig: a.oracleConfig as `0x${string}`,
    };

    try {
      await (await reg.updateAdapter(info)).wait();
      console.log("adapter updated");
    } catch {
      await (await reg.registerAdapter(info)).wait();
      console.log("adapter registered");
    }
  });

// perpbond:set-alloc
task("perpbond:set-alloc", "Set Vault target allocations (must sum to 10000)")
  .addParam("vault")
  .addParam("adapters", "CSV addresses")
  .addParam("bps", "CSV bps")
  .setAction(async (a, hre) => {
    const [signer] = await hre.ethers.getSigners();
    const vault = await hre.ethers.getContractAt("PerpBondVault", a.vault, signer);

    const adapters = parseCsv(a.adapters, ethers.getAddress);
    const bps = parseCsv(a.bps, (s) => Number(s));
    const sum = bps.reduce((x, y) => x + y, 0);
    if (sum !== 10000) throw new Error(`bps must sum to 10000, got ${sum}`);

    await (await vault.setTargetAllocations(adapters, bps)).wait();
    console.log("allocations set");
  });

// perpbond:wires
task("perpbond:wires", "Wire Harvester<->Distributor and set fee bps")
  .addParam("harvester")
  .addParam("distributor")
  .addOptionalParam("feeBps", "default 1000", "1000")
  .setAction(async (a, hre) => {
    const [signer] = await hre.ethers.getSigners();
    const harvester = await hre.ethers.getContractAt("Harvester", a.harvester, signer);
    const distributor = await hre.ethers.getContractAt("Distributor", a.distributor, signer);

    await (await harvester.setDistributor(a.distributor)).wait();
    await (await distributor.setHarvester(a.harvester)).wait();
    await (await distributor.setFeeBps(Number(a.feeBps))).wait();
    console.log("wires/fees set");
  });

// perpbond:list
task("perpbond:list", "List adapters from the registry")
  .addParam("registry")
  .setAction(async (a, hre) => {
    const [signer] = await hre.ethers.getSigners();
    const reg = await hre.ethers.getContractAt("AdapterRegistry", a.registry, signer);
    const list = await reg.list();
    console.table(list.map((i: any) => ({
      adapter: i.adapter,
      active: i.active,
      tvlCapUSDC: i.tvlCapUSDC.toString(),
      maxBps: i.maxBpsOfVault,
      maxSlip: i.maxSlippageBpsOnSwap
    })));
  });

// perpbond:quote-minout
task("perpbond:quote-minout", "Quote oracle minOut via RouterGuard")
  .addParam("guard")
  .addParam("tokenIn")
  .addParam("tokenOut")
  .addParam("amountIn", "amount in tokenIn decimals")
  .setAction(async (a, hre) => {
    const [signer] = await hre.ethers.getSigners();
    const guard = await hre.ethers.getContractAt("RouterGuard", a.guard, signer);
    const out = await guard.quoteMinOut(a.tokenIn, a.tokenOut, a.amountIn);
    console.log(`minOut: ${out.toString()}`);
  });

