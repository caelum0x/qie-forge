"use client";

import { useCallback, useEffect, useState } from "react";
import { encodeFunctionData, formatEther, parseUnits } from "viem";
import { useWallet } from "./WalletProvider";
import { ERC20_ABI, VAULT_ABI } from "@/lib/contracts";
import { ShieldIcon } from "./icons";

interface Position {
  collateral: string;
  debtPrincipal: string;
  healthFactor: string;
  currentDebt: string;
}

const WAD = 10n ** 18n;

export function VaultCard({
  vaultAddress,
  collateralAddress,
  collateralDecimals,
}: {
  vaultAddress: `0x${string}`;
  collateralAddress: `0x${string}`;
  collateralDecimals: number;
}) {
  const { provider, address, connect } = useWallet();
  const [position, setPosition] = useState<Position | undefined>(undefined);
  const [depositAmount, setDepositAmount] = useState("");
  const [status, setStatus] = useState<string | undefined>(undefined);

  const refresh = useCallback(async () => {
    if (!address) return;
    const res = await fetch(`/api/vault-position?user=${address}`);
    const data = await res.json();
    if (!data.error) setPosition(data);
  }, [address]);

  useEffect(() => {
    if (!address) return;
    // Fetching the position on mount / when the connected address changes
    // is the one case React's docs explicitly carve out as a legitimate
    // effect (synchronizing with an external system — the chain — not
    // deriving state from props). The actual `setPosition` call happens
    // inside `refresh`'s async body, after the fetch resolves, not
    // synchronously in this effect.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void refresh();
  }, [address, refresh]);

  async function handleDeposit() {
    if (!provider || !address || !depositAmount) return;
    setStatus("Approving collateral…");
    try {
      const amount = parseUnits(depositAmount, collateralDecimals);
      const approveData = encodeFunctionData({
        abi: ERC20_ABI,
        functionName: "approve",
        args: [vaultAddress, amount],
      });
      await provider.request({
        method: "eth_sendTransaction",
        params: [{ from: address, to: collateralAddress, data: approveData }],
      });

      setStatus("Depositing collateral…");
      const depositData = encodeFunctionData({
        abi: VAULT_ABI,
        functionName: "depositCollateral",
        args: [amount],
      });
      const txHash = await provider.request({
        method: "eth_sendTransaction",
        params: [{ from: address, to: vaultAddress, data: depositData }],
      });
      setStatus(`Deposit submitted: ${String(txHash)}`);
      refresh();
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "Deposit failed");
    }
  }

  const healthFactorDisplay = position
    ? position.debtPrincipal === "0"
      ? "—"
      : (Number(position.healthFactor) / Number(WAD)).toFixed(2)
    : "—";
  const isRisky = position && position.debtPrincipal !== "0" && BigInt(position.healthFactor) < WAD + WAD / 5n;

  return (
    <div className="card p-6 max-w-md">
      <div className="flex items-center gap-2 text-sm text-muted mb-4">
        <ShieldIcon className="w-4 h-4" /> Lending Vault
      </div>

      {!address ? (
        <button onClick={() => connect(1983)} className="btn-primary w-full py-2.5 text-sm">
          Connect Wallet
        </button>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 mb-4">
            <Stat label="Collateral" value={position ? formatEther(BigInt(position.collateral)) : "—"} />
            <Stat label="Debt" value={position ? formatUnitsSafe(position.currentDebt) : "—"} />
            <Stat
              label="Health factor"
              value={healthFactorDisplay}
              danger={Boolean(isRisky)}
            />
          </div>

          <div className="input-field p-3 mb-3">
            <p className="text-xs text-muted mb-1">Deposit collateral</p>
            <input
              className="w-full bg-transparent outline-none text-lg text-foreground"
              placeholder="0.0"
              value={depositAmount}
              onChange={(e) => setDepositAmount(e.target.value)}
            />
          </div>

          <button onClick={handleDeposit} disabled={!depositAmount} className="btn-primary w-full py-2.5 text-sm">
            Deposit
          </button>
        </>
      )}

      {status && <p className="mt-3 text-xs text-muted break-all">{status}</p>}
    </div>
  );
}

function formatUnitsSafe(raw: string): string {
  try {
    return (Number(raw) / 1e6).toFixed(2); // vault's borrow asset in this demo config is 6-decimals
  } catch {
    return raw;
  }
}

function Stat({ label, value, danger }: { label: string; value: string; danger?: boolean }) {
  return (
    <div>
      <p className="text-xs text-muted">{label}</p>
      <p className={`text-lg font-semibold ${danger ? "text-danger" : "text-foreground"}`}>{value}</p>
    </div>
  );
}
