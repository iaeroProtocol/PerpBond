// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {AdapterRegistry} from "../contracts/AdapterRegistry.sol";
import {PerpBondVault} from "../contracts/PerpBondVault.sol";
import {RouterGuard} from "../contracts/RouterGuard.sol";
import {Harvester} from "../contracts/Harvester.sol";
import {Distributor} from "../contracts/Distributor.sol";
import {AerodromeVeAdapter} from "../contracts/AerodromeVeAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ConfigurePerpBondBase is Script {
    // ---- Env (fill these before running) ----
    address GOV      = vm.envAddress("GOVERNOR");
    address GUARD    = vm.envAddress("GUARDIAN");
    address KEEP     = vm.envAddress("KEEPER");
    address TRES     = vm.envAddress("TREASURY");

    address USDC     = vm.envAddress("USDC");
    address WETH     = vm.envAddress("WETH");
    address AERO     = vm.envAddress("AERO");
    address UNI_V3   = vm.envAddress("UNIV3_ROUTER");

    address REG      = vm.envAddress("REGISTRY");
    address VAULT    = vm.envAddress("VAULT");
    address GUARD_C  = vm.envAddress("ROUTER_GUARD");
    address HARV     = vm.envAddress("HARVESTER");
    address DIST     = vm.envAddress("DISTRIBUTOR");
    address ADAPT    = vm.envAddress("AERO_ADAPTER");

    // Optional Chainlink feeds & settings (token/USD, staleness secs, token decimals)
    address FEED_USDC = vm.envOr("FEED_USDC", address(0));
    address FEED_WETH = vm.envOr("FEED_WETH", address(0));
    address FEED_AERO = vm.envOr("FEED_AERO", address(0));
    uint48  STALE     = uint48(vm.envOr("FEED_STALE_AFTER", uint256(3600)));
    uint8   DEC_USDC  = uint8(vm.envOr("DEC_USDC", uint256(6)));
    uint8   DEC_WETH  = uint8(vm.envOr("DEC_WETH", uint256(18)));
    uint8   DEC_AERO  = uint8(vm.envOr("DEC_AERO", uint256(18)));

    // Uni v3 fee tiers (500=0.05%, 3000=0.3%, 10000=1%)
    uint24 FEE_USDC_WETH = uint24(vm.envOr("FEE_USDC_WETH", uint256(500)));
    uint24 FEE_WETH_AERO = uint24(vm.envOr("FEE_WETH_AERO", uint256(3000)));
    uint24 FEE_AERO_WETH = uint24(vm.envOr("FEE_AERO_WETH", uint256(3000)));
    uint24 FEE_WETH_USDC = uint24(vm.envOr("FEE_WETH_USDC", uint256(500)));

    // Slippage guard (bps)
    uint16  MAX_SLIP_USDC_AERO = uint16(vm.envOr("MAX_SLIP_USDC_AERO", uint256(100))); // 1.00%
    uint16  MAX_SLIP_AERO_USDC = uint16(vm.envOr("MAX_SLIP_AERO_USDC", uint256(100))); // 1.00%

    // Distributor fee (bps)
    uint16  DIST_FEE_BPS = uint16(vm.envOr("DIST_FEE_BPS", uint256(1000))); // 10%

    function run() external {
        vm.startBroadcast(GOV);

        AdapterRegistry registry   = AdapterRegistry(REG);
        PerpBondVault  vault       = PerpBondVault(VAULT);
        RouterGuard    guard       = RouterGuard(GUARD_C);
        Harvester      harvester   = Harvester(HARV);
        Distributor    distributor = Distributor(DIST);
        AerodromeVeAdapter adapter = AerodromeVeAdapter(ADAPT);

        // 1) Guard: allow router, set slippage, set feeds (if provided)
        guard.setRouterAllowed(UNI_V3, true);
        guard.setMaxSlippageBps(USDC, AERO, MAX_SLIP_USDC_AERO);
        guard.setMaxSlippageBps(AERO, USDC, MAX_SLIP_AERO_USDC);

        if (FEED_USDC != address(0)) guard.setFeed(USDC, FEED_USDC, STALE, DEC_USDC);
        if (FEED_WETH != address(0)) guard.setFeed(WETH, FEED_WETH, STALE, DEC_WETH);
        if (FEED_AERO != address(0)) guard.setFeed(AERO, FEED_AERO, STALE, DEC_AERO);

        // 2) Registry: register/update adapter config; make active
        AdapterRegistry.AdapterInfo memory info = AdapterRegistry.AdapterInfo({
            active: true,
            adapter: ADAPT,
            tvlCapUSDC: 0,                 // 0 = uncapped (set if you want a hard cap)
            maxBpsOfVault: 10_000,         // allow up to 100% for initial testing
            maxSlippageBpsOnSwap: 150,     // used by policies if you wire them
            oracleConfig: bytes("")
        });

        // Try update first; if not registered, register
        try registry.getAdapter(ADAPT) returns (AdapterRegistry.AdapterInfo memory) {
            registry.updateAdapter(info);
        } catch {
            registry.registerAdapter(info);
        }
        registry.setAdapterActive(ADAPT, true);

        // 3) Vault: set 100% target allocation to this adapter
        address;
        adapters[0] = ADAPT;
        uint16;
        bps[0] = 10_000;
        vault.setTargetAllocations(adapters, bps);

        // 4) Adapter: plug router/guard + routes (USDC→WETH→AERO, and back)
        adapter.setRouter(UNI_V3);
        adapter.setGuard(address(guard));

        // Build encoded paths
        bytes memory pathUSDCtoAERO = _encodePath2Hop(USDC, FEE_USDC_WETH, WETH, FEE_WETH_AERO, AERO);
        bytes memory pathAEROtoUSDC = _encodePath2Hop(AERO, FEE_AERO_WETH, WETH, FEE_WETH_USDC, USDC);

        adapter.setDepositRoute(pathUSDCtoAERO, 0);
        adapter.setExitRoute(pathAEROtoUSDC, 0);

        // 5) Harvester ⇄ Distributor & Fees
        harvester.setDistributor(address(distributor)); // also sets USDC allowance internally
        distributor.setHarvester(address(harvester));
        distributor.setFeeBps(DIST_FEE_BPS);

        vm.stopBroadcast();
    }

    // Encodes tokenA -> tokenB -> tokenC with feeAB, feeBC
    function _encodePath2Hop(
        address tokenA, uint24 feeAB, address tokenB, uint24 feeBC, address tokenC
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(tokenA, feeAB, tokenB, feeBC, tokenC);
    }
}
