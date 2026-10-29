"use client";

import { useWallet } from "./WalletProvider";
import { WalletIcon } from "./icons";

function short(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function WalletConnectButton() {
  const { address, connecting, error, connect } = useWallet();

  if (address) {
    return (
      <span className="inline-flex items-center gap-2 rounded-xl border border-border px-3 py-1.5 text-sm text-foreground">
        <WalletIcon className="w-4 h-4 text-muted" />
        {short(address)}
      </span>
    );
  }

  return (
    <div className="flex flex-col items-end gap-1">
      <button
        onClick={() => connect()}
        disabled={connecting}
        className="btn-primary inline-flex items-center gap-2 px-4 py-2 text-sm"
      >
        <WalletIcon className="w-4 h-4" />
        {connecting ? "Connecting…" : "Connect Wallet"}
      </button>
      {error && <span className="text-xs text-danger max-w-[220px] text-right">{error}</span>}
    </div>
  );
}
