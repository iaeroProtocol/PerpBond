"use client";
import { useEffect, useState } from "react";
import { getAutoCompound, setAutoCompound } from "@/lib/sdk";

export default function ToggleAutoCompound(){
  const [on,setOn]=useState<boolean>(false);
  useEffect(()=>{ getAutoCompound().then(setOn); },[]);
  return (
    <div className="rounded-2xl bg-neutral-900 p-4 max-w-md flex items-center justify-between">
      <div>
        <div className="text-lg">Auto-compound</div>
        <div className="text-neutral-400 text-sm">Re-invest USDC distributions automatically</div>
      </div>
      <button onClick={async()=>{ const n=!on; await setAutoCompound(n); setOn(n);}} className="rounded-xl bg-white/10 hover:bg-white/20 px-3 py-2">
        {on?'On':'Off'}
      </button>
    </div>
  );
}

