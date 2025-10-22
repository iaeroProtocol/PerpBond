"use client";
import { useEffect, useState } from "react";
import { getAdapters } from "@/lib/sdk";
export default function StrategyPage(){
  const [adapters,setAdapters]=useState<{name:string; cap:number; active:boolean}[]>([]);
  useEffect(()=>{ getAdapters().then(setAdapters).catch(()=>{}); },[]);
  return (
    <div className="rounded-2xl bg-neutral-900 p-4">
      <h2 className="text-xl mb-3">Adapters</h2>
      {adapters.map(a=>(
        <div key={a.name} className="flex justify-between border-b border-neutral-800 py-2 last:border-none">
          <span>{a.name}</span><span className="text-neutral-400">Cap: ${a.cap.toLocaleString()} {a.active?'• active':'• paused'}</span>
        </div>
      ))}
      {!adapters.length && <div className="text-neutral-400">Loading…</div>}
    </div>
  );
}

