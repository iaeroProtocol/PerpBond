"use client";

import React, { useMemo, useState, useEffect } from "react";
import dynamic from "next/dynamic";

import { useAccount, useWalletClient } from "wagmi";

import {
  sdkGetOverview,
  sdkGetAdapters,
  sdkGetEpochs,
  sdkGetClaimableUSDC,
  sdkClaimUSDCWith,
  sdkGetAutoCompound,
  sdkSetAutoCompoundWith,
  sdkDepositUSDCWith,
  sdkGetUsdcBalance,
} from "@/lib/sdk";

const Connect = dynamic(() => import("./Connect"), { ssr: false });

/* ---------- Types ---------- */
type Overview = { tvl: number; apy: number; allocations: { name: string; bps: number }[] };
type AdapterRow = { name: string; cap: number; active: boolean; tvl: number; apy: number };
type EpochRow = { epochId: number; date: string; usdc: number; apy: number };

/* ---------- Utils ---------- */
function formatUSD(n: number) {
  if (!Number.isFinite(n)) return "—";
  return n < 1000 ? `$${n.toFixed(2)}` : `$${n.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
}
function formatPct(d: number) {
  if (!Number.isFinite(d)) return "—";
  return `${(d * 100).toFixed(2)}%`;
}

/* ---------- Main Component ---------- */
export default function PerpBondApp() {

  const [loading, setLoading] = useState(true);
  const [overview, setOverview] = useState<Overview | null>(null);
  const [adapters, setAdapters] = useState<AdapterRow[]>([]);
  const [epochs, setEpochs] = useState<EpochRow[]>([]);
  const [claimable, setClaimable] = useState<string>("0.00");
  const [autoCompound, setAutoCompound] = useState<boolean>(false);
  const { address: acct } = useAccount();
  const { data: wallet } = useWalletClient();

  const [usdcBal, setUsdcBal] = useState<string>("0.00");

  useEffect(() => {
    (async () => {
      setUsdcBal("0.00");
      if (!acct) return;
      setUsdcBal(await sdkGetUsdcBalance(acct));
    })();
  }, [acct]);


  useEffect(() => {
    (async () => {
      setLoading(true);
      try {
        const [ov, ads, eps] = await Promise.all([
          sdkGetOverview(),
          sdkGetAdapters(),
          sdkGetEpochs(),
        ]);
        setOverview(ov);
        setAdapters(ads);
        setEpochs(eps);
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  // refresh user-dependent reads when wallet changes
  useEffect(() => {
    (async () => {
      setClaimable("0.00");
      setAutoCompound(false);
      if (!acct) return;
      const [cl, ac] = await Promise.all([
        sdkGetClaimableUSDC(acct),
        sdkGetAutoCompound(acct),
      ]);
      setClaimable(cl);
      setAutoCompound(ac);
    })();
  }, [acct]);

  return (
    <div className="min-h-screen bg-neutral-950 text-neutral-100">
      <div className="mx-auto max-w-6xl p-6 md:p-10 space-y-8">
        <Header />

        <section>
          <div className="grid gap-4 md:grid-cols-3">
            <StatCard label="TVL" value={overview ? formatUSD(overview.tvl) : "—"} />
            <StatCard label="Projected Net APY" value={overview ? `${formatPct(overview.apy)}` : "—"} />
            <StatCard label="Adapters" value={overview ? String(overview.allocations.length) : "—"} />
          </div>
        </section>

        <section className="grid gap-6 md:grid-cols-2">
          <DepositCard
            onDeposit={async (amt) => { await sdkDepositUSDCWith(wallet, acct, amt); }}
            disabledReason={!acct ? "Connect wallet" : undefined}
            usdcBalance={usdcBal}
          />

          <ClaimCard
            claimable={claimable}
            onClaim={async () => {
              await sdkClaimUSDCWith(wallet);
              if (acct) {
                const cl = await sdkGetClaimableUSDC(acct);
                setClaimable(cl);
              }
            }}
            disabledReason={!acct ? "Connect wallet" : undefined}
          />
        </section>

        <section className="grid gap-6 md:grid-cols-2">
          <AllocationCard allocations={overview?.allocations ?? []} />
          <AutoCompoundCard
            on={autoCompound}
            toggle={async () => {
              const next = !autoCompound;
              await sdkSetAutoCompoundWith(wallet, next);
              setAutoCompound(next);
            }}
            disabledReason={!acct ? "Connect wallet" : undefined}
          />
        </section>

        <section>
          <AdaptersCard rows={adapters} loading={loading} />
        </section>

        <section>
          <EpochsCard rows={epochs} />
        </section>

        <Footer />
      </div>
    </div>
  );
}

/* ---------- Subcomponents ---------- */

function Header() {
  return (
    <header className="flex items-center justify-between">
      <div className="space-y-1">
        <h1 className="text-2xl md:text-3xl font-semibold tracking-tight">Perpetual DeFi Bond</h1>
        <p className="text-neutral-400 text-sm">USDC-in / USDC-yield across veAERO, vePENDLE, vlCVX</p>
      </div>
      <Connect />
    </header>
  );
}

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-white/5 p-5">
      <div className="text-neutral-400 text-sm">{label}</div>
      <div className="mt-2 text-2xl font-medium">{value}</div>
    </div>
  );
}

function DepositCard({
    onDeposit, disabledReason, usdcBalance,
  }: { onDeposit: (amt: string) => Promise<void>; disabledReason?: string; usdcBalance?: string }) {
  const [amt, setAmt] = useState("");
  const [busy, setBusy] = useState(false);
  const disabled = !!disabledReason || busy || !amt || Number(amt) <= 0;

  return (
    <div className="rounded-2xl border border-white/10 bg-white/5 p-5">
      <div className="mb-3 flex items-center justify-between">
        <h3 className="text-lg font-medium">Deposit USDC</h3>
        <span className="text-xs text-neutral-400">Receipt: PerpBond</span>
      </div>
      <div className="space-y-3">
        <div className="flex rounded-xl overflow-hidden border border-white/10">
          <input
            inputMode="decimal"
            value={amt}
            onChange={(e) => setAmt(e.target.value)}
            placeholder="0.00"
            className="w-full bg-neutral-900/60 px-4 py-3 outline-none"
          />
          <div className="flex items-center gap-2 bg-neutral-900/60 px-3 text-sm text-neutral-300">USDC</div>
        </div>
        
        <div className="text-xs text-neutral-400">
          Wallet: {usdcBalance ?? "—"} USDC
        </div>

        <div className="flex gap-2">
          <button
            disabled={disabled}
            onClick={async () => {
              setBusy(true);
              try {
                await onDeposit(amt);
                setAmt("");
              } finally {
                setBusy(false);
              }
            }}
            className={`rounded-xl px-4 py-2 text-sm font-medium transition ${
              disabled ? "bg-white/10 text-neutral-500" : "bg-white/90 text-neutral-900 hover:bg-white"
            }`}
            title={disabledReason}
          >
            {busy ? "Depositing…" : disabledReason ?? "Deposit"}
          </button>
          <button 
            onClick={() => setAmt(usdcBalance || "0")} 
            disabled={!usdcBalance || Number(usdcBalance) === 0}
            className="rounded-xl px-3 py-2 text-sm border border-white/10 hover:bg-white/5 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Max
          </button>
          <button onClick={() => setAmt("1000")} className="rounded-xl px-3 py-2 text-sm border border-white/10 hover:bg-white/5">$1k</button>
          <button onClick={() => setAmt("10000")} className="rounded-xl px-3 py-2 text-sm border border-white/10 hover:bg-white/5">$10k</button>
        </div>
        <p className="text-xs text-neutral-400">Principal is non-redeemable. Yield is distributed in USDC weekly/monthly.</p>
      </div>
    </div>
  );
}

function ClaimCard({ claimable, onClaim, disabledReason }: { claimable: string; onClaim: () => Promise<void>; disabledReason?: string }) {
  const [busy, setBusy] = useState(false);
  const disabled = !!disabledReason || busy;
  return (
    <div className="rounded-2xl border border-white/10 bg-white/5 p-5">
      <div className="mb-3 flex items-center justify-between">
        <h3 className="text-lg font-medium">Claimable USDC</h3>
        <span className="text-xs text-neutral-400">Weekly/Monthly</span>
      </div>
      <div className="flex items-end justify-between">
        <div className="text-3xl font-medium">{claimable}</div>
        <button
          onClick={async () => { setBusy(true); try { await onClaim(); } finally { setBusy(false); } }}
          disabled={disabled}
          className={`rounded-xl px-4 py-2 text-sm font-medium transition ${
            disabled ? "bg-white/10 text-neutral-500" : "bg-white/90 text-neutral-900 hover:bg-white"
          }`}
          title={disabledReason}
        >
          {busy ? "Claiming…" : disabledReason ?? "Claim"}
        </button>
      </div>
    </div>
  );
}

function AutoCompoundCard({ on, toggle, disabledReason }: { on: boolean; toggle: () => Promise<void>; disabledReason?: string }) {
  const [busy, setBusy] = useState(false);
  return (
    <div className="rounded-2xl border border-white/10 bg-white/5 p-5 flex items-center justify-between">
      <div>
        <div className="text-lg font-medium">Auto-Compound</div>
        <div className="text-sm text-neutral-400">Automatically re-invest your USDC distributions into new PerpBond shares.</div>
      </div>
      <button
        onClick={async () => { setBusy(true); try { await toggle(); } finally { setBusy(false); } }}
        disabled={!!disabledReason}
        className={`rounded-xl px-4 py-2 text-sm border border-white/10 ${
          on ? "bg-emerald-500/20 text-emerald-300" : "bg-white/5 text-neutral-200"
        } disabled:opacity-50`}
        title={disabledReason}
      >
        {busy ? "…" : on ? "On" : "Off"}
      </button>
    </div>
  );
}

function AllocationCard({ allocations }: { allocations: { name: string; bps: number }[] }) {
  const totalBps = useMemo(() => allocations.reduce((a, b) => a + b.bps, 0), [allocations]);
  return (
    <div className="rounded-2xl border border-white/10 bg-white/5 p-5">
      <h3 className="mb-3 text-lg font-medium">Portfolio Allocation</h3>
      {!allocations.length ? (
        <div className="text-neutral-400 text-sm">No allocations yet.</div>
      ) : (
        <div className="space-y-2">
          {allocations.map((a) => (
            <div key={a.name} className="flex items-center gap-3">
              <div className="w-40 text-sm text-neutral-300">{a.name}</div>
              <div className="flex-1 h-2 rounded-full bg-neutral-800 overflow-hidden">
                <div className="h-2 bg-white/80" style={{ width: `${(a.bps / Math.max(totalBps, 1)) * 100}%` }} />
              </div>
              <div className="w-16 text-right text-sm text-neutral-400">{formatPct(a.bps / 10000)}</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function AdaptersCard({ rows, loading }: { rows: AdapterRow[]; loading?: boolean }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-white/5 p-5">
      <h3 className="mb-3 text-lg font-medium">Adapters</h3>
      {loading && !rows.length ? (
        <div className="text-neutral-400 text-sm">Loading…</div>
      ) : (
        <div className="divide-y divide-white/10">
          {rows.map((r) => (
            <div key={r.name} className="grid grid-cols-2 md:grid-cols-5 gap-2 py-3 text-sm">
              <div className="font-medium">{r.name}</div>
              <div className="text-neutral-300">Cap: {formatUSD(r.cap)}</div>
              <div className="text-neutral-300">Active: {r.active ? "Yes" : "No"}</div>
              <div className="text-neutral-300">TVL: {formatUSD(r.tvl)}</div>
              <div className="text-neutral-300">APY: {formatPct(r.apy)}</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function EpochsCard({ rows }: { rows: EpochRow[] }) {
  return (
    <div className="rounded-2xl border border-white/10 bg-white/5 p-5">
      <h3 className="mb-3 text-lg font-medium">Epoch Distributions</h3>
      {!rows.length ? (
        <div className="text-neutral-400 text-sm">No epochs yet.</div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-neutral-400">
              <tr className="text-left">
                <th className="py-2">Epoch</th>
                <th className="py-2">Date</th>
                <th className="py-2">USDC Distributed</th>
                <th className="py-2">Realized APY</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-white/10">
              {rows.map((e) => (
                <tr key={e.epochId}>
                  <td className="py-2">#{e.epochId}</td>
                  <td className="py-2">{e.date}</td>
                  <td className="py-2">{formatUSD(e.usdc)}</td>
                  <td className="py-2">{formatPct(e.apy)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function Footer() {
  return <footer className="py-6 text-center text-xs text-neutral-500">© {new Date().getFullYear()} Perpetual DeFi Bond</footer>;
}