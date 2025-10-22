"use client";
import { useEffect, useState } from "react";
import { getClaimableUSDC, claimUSDC } from "@/lib/sdk";

export default function ClaimCard(){
  const [claimable,setClaimable]=useState<string>("—");
  const [busy,setBusy]=useState(false);
  useEffect(()=>{ getClaimableUSDC().then(v=>setClaimable(v)); },[]);
  return (
    <div className="rounded-2xl bg-neutral-900 p-4 grid gap-3 max-w-md">
      <h3 className="text-lg">Claimable USDC</h3>
      <div className="text-2xl">{claimable}</div>
      <button disabled={busy} onClick={async()=>{ setBusy(true); try{ await claimUSDC(); } finally{ setBusy(false); }}} className="rounded-xl bg-white/10 hover:bg-white/20 p-2">{busy?'Claiming…':'Claim'}</button>
    </div>
  );
}

