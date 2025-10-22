"use client";

import { useConnect, useAccount, useDisconnect } from "wagmi";
import { useEffect, useState } from "react";

export default function Connect() {
  const [mounted, setMounted] = useState(false);
  const [showMenu, setShowMenu] = useState(false);
  const { connectors, connect, isPending, error } = useConnect();
  const { address, isConnected } = useAccount();
  const { disconnect } = useDisconnect();

  // Mount effect
  useEffect(() => {
    setMounted(true);
  }, []);

  // Close menu when clicking outside
  useEffect(() => {
    if (!showMenu) return;
    
    const handleClick = () => setShowMenu(false);
    document.addEventListener('click', handleClick);
    return () => document.removeEventListener('click', handleClick);
  }, [showMenu]);

  if (!mounted) {
    return (
      <div className="rounded-xl border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium text-neutral-500">
        Loading...
      </div>
    );
  }

  if (isConnected && address) {
    return (
      <div className="flex items-center gap-3">
        <span className="text-sm text-neutral-400">
          {address.slice(0, 6)}...{address.slice(-4)}
        </span>
        <button
          onClick={() => disconnect()}
          className="rounded-xl border border-white/10 bg-white/5 px-4 py-2 text-sm font-medium hover:bg-white/10 transition"
        >
          Disconnect
        </button>
      </div>
    );
  }

  return (
    <div className="relative">
      <button
        onClick={(e) => {
          e.stopPropagation();
          setShowMenu(!showMenu);
        }}
        disabled={isPending}
        className="rounded-xl bg-white/90 px-4 py-2 text-sm font-medium text-neutral-900 hover:bg-white transition disabled:bg-white/10 disabled:text-neutral-500"
      >
        {isPending ? "Connecting..." : "Connect Wallet"}
      </button>

      {showMenu && (
        <div className="absolute right-0 top-full mt-2 w-64 rounded-xl border border-white/10 bg-neutral-900 p-2 shadow-xl z-50">
          {connectors.map((connector) => {
            const displayName = connector.name === 'Injected' ? 'Browser Wallet' : connector.name;
            
            return (
              <button
                key={connector.uid}
                onClick={(e) => {
                  e.stopPropagation();
                  connect({ connector });
                  setShowMenu(false);
                }}
                disabled={isPending}
                className="w-full text-left rounded-lg px-4 py-3 text-sm hover:bg-white/5 transition disabled:opacity-50 flex items-center justify-between"
              >
                <span>{displayName}</span>
                {connector.type === 'walletConnect' && (
                  <span className="text-xs text-neutral-500">QR Code</span>
                )}
              </button>
            );
          })}
        </div>
      )}

      {error && (
        <div className="absolute right-0 top-full mt-2 w-64 rounded-xl border border-red-500/20 bg-red-500/10 p-3 text-xs text-red-400">
          {error.message}
        </div>
      )}
    </div>
  );
}
