"use client";

import { useConnect, useAccount, useDisconnect } from "wagmi";
import { useEffect, useState } from "react";

export default function ConnectPanel() {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  const { connectors, connect, isPending, error, status } = useConnect();
  const { address, chainId, isConnected } = useAccount();
  const { disconnect } = useDisconnect();

  if (!mounted) return null;

  // We only registered a single injected connector above
  const injected = connectors[0];

  return (
    <div style={{ display: "grid", gap: 12, maxWidth: 520, padding: 16, border: "1px solid #eee", borderRadius: 12 }}>
      <h3>Browser Wallet</h3>

      {isConnected ? (
        <>
          <div>Connected: {address} {chainId ? `(chain ${chainId})` : ""}</div>
          <button onClick={() => disconnect()} style={{ padding: 8 }}>Disconnect</button>
        </>
      ) : (
        <button
          onClick={() => connect({ connector: injected })}
          disabled={!injected?.ready || isPending}
          style={{ padding: 8 }}
          title={!injected?.ready ? "No browser wallet detected yet" : undefined}
        >
          {injected?.ready ? "Connect Browser Wallet" : "Detecting wallet..."}
        </button>
      )}

      <small style={{ opacity: 0.7 }}>
        status: {status} | pending: {String(isPending)} | connector: {injected?.name ?? "n/a"}
      </small>

      {error && (
        <div style={{ color: "crimson" }}>
          <strong>Error:</strong> {error.message}
        </div>
      )}

      {!injected?.ready && (
        <small>
          Tip: open this site in a browser with MetaMask/Rabby/Brave Wallet installed and enabled.
        </small>
      )}
    </div>
  );
}

