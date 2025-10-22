"use client";
import { useState } from "react";
import { depositUSDC } from "@/lib/sdk";

export default function DepositCard(){
  const [amt,setAmt]=useState("");
  const [busy,setBusy]=useState(false);
  const onDeposit=async()=>{
    setBusy(true);
    try{ await depositUSDC(amt); } finally{ setBusy(false); }
  };
  return (
    <div className="rounded-2xl bg-neutral-900 p-4 grid gap-3 max-w-md">
      <h3 className="text-lg">Deposit USDC</h3>
      <input value={amt} onChange={e=>setAmt(e.target.value)} placeholder="0.0" className="bg-neutral-800 p-2 rounded-xl outline-none"/>
      <button disabled={busy} onClick={onDeposit} className="rounded-xl bg-white/10 hover:bg-white/20 p-2">{busy?'Depositing…':'Deposit'}</button>
    </div>
  );
}

