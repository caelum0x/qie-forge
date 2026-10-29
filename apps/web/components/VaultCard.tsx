"use client";

import { useCallback, useEffect, useState } from "react";
import { encodeFunctionData, formatEther, formatUnits, parseUnits } from "viem";
import { useWallet } from "./WalletProvider";
import { VAULT_ABI } from "@/lib/contracts";
import { ensureAllowance, sendContractCall } from "@/lib/erc20Actions";
import { ShieldIcon } from "./icons";

interface Position {
  collateral: string;
  debtPrincipal: string;
  healthFactor: string;
  currentDebt: string;
  /** Severity-scaled liquidation bonus (bps) this position would pay a
   * liquidator right now — see QieForgeVault.liquidationBonusBpsFor. Rises
   * the more underwater the position gets, up to `liquidationBonusMaxBps`,
   * instead of a flat rate — a real early-warning signal, not just the
   * health factor alone. */
  liquidationBonusBps: string;
}

const WAD = 10n ** 18n;

/**
 * Borrower side of the vault: deposit/withdraw collateral, borrow/repay the
 * quote asset, with a live health factor. The lender side (supply/withdraw
 * liquidity) is a separate card — see LendCard.tsx — since it has its own
 * independent share accounting and isn't gated on having a borrow position.
 */
export function VaultCard({
  vaultAddress,
  collateralAddress,
  collateralDecimals,
  collateralSymbol = "Collateral",
  borrowAddress,
  borrowDecimals,
  borrowSymbol = "Borrowed asset",
}: {
  vaultAddress: `0x${string}`;
  collateralAddress: `0x${string}`;
  collateralDecimals: number;
  collateralSymbol?: string;
  borrowAddress?: `0x${string}`;
  borrowDecimals: number;
  borrowSymbol?: string;
}) {
  const { provider, address, connect } = useWallet();
  const [position, setPosition] = useState<Position | undefined>(undefined);
  const [depositAmount, setDepositAmount] = useState("");
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [borrowAmount, setBorrowAmount] = useState("");
  const [repayAmount, setRepayAmount] = useState("");
  const [status, setStatus] = useState<string | undefined>(undefined);
  const [pending, setPending] = useState<string | undefined>(undefined);

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

  async function runAction(label: string, action: () => Promise<string>) {
    if (!provider || !address) return;
    setPending(label);
    setStatus(`${label}…`);
    try {
      const txHash = await action();
      setStatus(`${label} submitted: ${txHash}`);
      await refresh();
    } catch (err) {
      setStatus(err instanceof Error ? err.message : `${label} failed`);
    } finally {
      setPending(undefined);
    }
  }

  function handleDeposit() {
    if (!depositAmount) return;
    runAction("Deposit collateral", async () => {
      const amount = parseUnits(depositAmount, collateralDecimals);
      await ensureAllowance(provider!, collateralAddress, address as `0x${string}`, vaultAddress, amount);
      const data = encodeFunctionData({ abi: VAULT_ABI, functionName: "depositCollateral", args: [amount] });
      return sendContractCall(provider!, address as `0x${string}`, vaultAddress, data);
    }).then(() => setDepositAmount(""));
  }

  function handleWithdrawCollateral() {
    if (!withdrawAmount) return;
    runAction("Withdraw collateral", async () => {
      const amount = parseUnits(withdrawAmount, collateralDecimals);
      const data = encodeFunctionData({ abi: VAULT_ABI, functionName: "withdrawCollateral", args: [amount] });
      return sendContractCall(provider!, address as `0x${string}`, vaultAddress, data);
    }).then(() => setWithdrawAmount(""));
  }

  function handleBorrow() {
    if (!borrowAmount) return;
    runAction("Borrow", async () => {
      const amount = parseUnits(borrowAmount, borrowDecimals);
      const data = encodeFunctionData({ abi: VAULT_ABI, functionName: "borrow", args: [amount] });
      return sendContractCall(provider!, address as `0x${string}`, vaultAddress, data);
    }).then(() => setBorrowAmount(""));
  }

  function handleRepay() {
    if (!repayAmount || !borrowAddress) return;
    runAction("Repay", async () => {
      const amount = parseUnits(repayAmount, borrowDecimals);
      await ensureAllowance(provider!, borrowAddress, address as `0x${string}`, vaultAddress, amount);
      const data = encodeFunctionData({ abi: VAULT_ABI, functionName: "repay", args: [amount] });
      return sendContractCall(provider!, address as `0x${string}`, vaultAddress, data);
    }).then(() => setRepayAmount(""));
  }

  const healthFactorDisplay = position
    ? position.debtPrincipal === "0"
      ? "—"
      : (Number(position.healthFactor) / Number(WAD)).toFixed(2)
    : "—";
  const isRisky = position && position.debtPrincipal !== "0" && BigInt(position.healthFactor) < WAD + WAD / 5n;
  const isUnderwater = position && position.debtPrincipal !== "0" && BigInt(position.healthFactor) < WAD;
  // Shown as "current rate if you were liquidated this instant" only once
  // a position is actually underwater (liquidationBonusBpsFor() returns
  // the flat base rate for a healthy position, which would be misleading
  // to display as if it were a live warning signal otherwise).
  const liquidationBonusDisplay =
    position && isUnderwater ? `${(Number(position.liquidationBonusBps) / 100).toFixed(2)}%` : "—";

  return (
    <div className="card p-6 max-w-md">
      <div className="flex items-center gap-2 text-sm text-muted mb-4">
        <ShieldIcon className="w-4 h-4" /> Lending Vault — Borrow
      </div>

      {!address ? (
        <button onClick={() => connect()} className="btn-primary w-full py-2.5 text-sm">
          Connect Wallet
        </button>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 mb-4">
            <Stat label="Collateral" value={position ? formatEther(BigInt(position.collateral)) : "—"} />
            <Stat
              label="Debt"
              value={position ? formatUnits(BigInt(position.currentDebt), borrowDecimals) : "—"}
            />
            <Stat label="Health factor" value={healthFactorDisplay} danger={Boolean(isRisky)} />
            {isUnderwater && (
              <Stat label="Liquidation bonus right now" value={liquidationBonusDisplay} danger />
            )}
          </div>

          <ActionRow
            label={`Deposit ${collateralSymbol}`}
            amount={depositAmount}
            onAmountChange={setDepositAmount}
            onSubmit={handleDeposit}
            busy={pending === "Deposit collateral"}
            disabledSubmit={!depositAmount}
          />
          <ActionRow
            label={`Withdraw ${collateralSymbol}`}
            amount={withdrawAmount}
            onAmountChange={setWithdrawAmount}
            onSubmit={handleWithdrawCollateral}
            busy={pending === "Withdraw collateral"}
            disabledSubmit={!withdrawAmount}
          />
          <ActionRow
            label={`Borrow ${borrowSymbol}`}
            amount={borrowAmount}
            onAmountChange={setBorrowAmount}
            onSubmit={handleBorrow}
            busy={pending === "Borrow"}
            disabledSubmit={!borrowAmount || !borrowAddress}
          />
          <ActionRow
            label={`Repay ${borrowSymbol}`}
            amount={repayAmount}
            onAmountChange={setRepayAmount}
            onSubmit={handleRepay}
            busy={pending === "Repay"}
            disabledSubmit={!repayAmount || !borrowAddress}
            last
          />
        </>
      )}

      {status && <p className="mt-3 text-xs text-muted break-all">{status}</p>}
    </div>
  );
}

function ActionRow({
  label,
  amount,
  onAmountChange,
  onSubmit,
  busy,
  disabledSubmit,
  last,
}: {
  label: string;
  amount: string;
  onAmountChange: (v: string) => void;
  onSubmit: () => void;
  busy: boolean;
  disabledSubmit: boolean;
  last?: boolean;
}) {
  return (
    <div className={last ? "" : "mb-3"}>
      <div className="input-field p-3 mb-2">
        <p className="text-xs text-muted mb-1">{label}</p>
        <input
          className="w-full bg-transparent outline-none text-lg text-foreground"
          placeholder="0.0"
          value={amount}
          onChange={(e) => onAmountChange(e.target.value)}
        />
      </div>
      <button onClick={onSubmit} disabled={disabledSubmit || busy} className="btn-primary w-full py-2 text-sm">
        {busy ? "Confirming…" : label}
      </button>
    </div>
  );
}

function Stat({ label, value, danger }: { label: string; value: string; danger?: boolean }) {
  return (
    <div>
      <p className="text-xs text-muted">{label}</p>
      <p className={`text-lg font-semibold ${danger ? "text-danger" : "text-foreground"}`}>{value}</p>
    </div>
  );
}

export type { Position as VaultPosition };
