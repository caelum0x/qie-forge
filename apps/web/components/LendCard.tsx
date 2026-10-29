"use client";

import { useCallback, useEffect, useState } from "react";
import { encodeFunctionData, formatUnits, parseUnits } from "viem";
import { useWallet } from "./WalletProvider";
import { VAULT_ABI } from "@/lib/contracts";
import { ensureAllowance, sendContractCall } from "@/lib/erc20Actions";
import { CoinsIcon } from "./icons";

interface PoolStats {
  lenderShares: string;
  totalLenderShares: string;
  totalAssets: string;
  totalDebtPrincipal: string;
}

/**
 * Lender side of QieForgeVault.deposit()/withdraw() — ERC4626-style share
 * accounting added in commit f55e3c6. This had contract support and SDK
 * coverage but no frontend surface at all until this pass: the live demo's
 * /vault page only ever exposed the borrower's depositCollateral().
 */
export function LendCard({
  vaultAddress,
  borrowAddress,
  borrowDecimals,
  borrowSymbol = "the quote asset",
}: {
  vaultAddress: `0x${string}`;
  borrowAddress: `0x${string}`;
  borrowDecimals: number;
  borrowSymbol?: string;
}) {
  const { provider, address, connect } = useWallet();
  const [stats, setStats] = useState<PoolStats | undefined>(undefined);
  const [supplyAmount, setSupplyAmount] = useState("");
  const [withdrawShares, setWithdrawShares] = useState("");
  const [status, setStatus] = useState<string | undefined>(undefined);
  const [pending, setPending] = useState<string | undefined>(undefined);

  const refresh = useCallback(async () => {
    if (!address) return;
    const res = await fetch(`/api/vault-position?user=${address}`);
    const data = await res.json();
    if (!data.error) setStats(data);
  }, [address]);

  useEffect(() => {
    if (!address) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void refresh();
  }, [address, refresh]);

  const idleLiquidity =
    stats && BigInt(stats.totalAssets) >= BigInt(stats.totalDebtPrincipal)
      ? BigInt(stats.totalAssets) - BigInt(stats.totalDebtPrincipal)
      : 0n;

  const yourShareValue =
    stats && BigInt(stats.totalLenderShares) > 0n
      ? (BigInt(stats.lenderShares) * BigInt(stats.totalAssets)) / BigInt(stats.totalLenderShares)
      : 0n;

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

  function handleSupply() {
    if (!supplyAmount) return;
    runAction("Supply liquidity", async () => {
      const amount = parseUnits(supplyAmount, borrowDecimals);
      await ensureAllowance(provider!, borrowAddress, address as `0x${string}`, vaultAddress, amount);
      const data = encodeFunctionData({ abi: VAULT_ABI, functionName: "deposit", args: [amount] });
      return sendContractCall(provider!, address as `0x${string}`, vaultAddress, data);
    }).then(() => setSupplyAmount(""));
  }

  function handleWithdraw() {
    if (!withdrawShares) return;
    runAction("Withdraw liquidity", async () => {
      const shares = parseUnits(withdrawShares, 18);
      const data = encodeFunctionData({ abi: VAULT_ABI, functionName: "withdraw", args: [shares] });
      return sendContractCall(provider!, address as `0x${string}`, vaultAddress, data);
    }).then(() => setWithdrawShares(""));
  }

  function fillMaxShares() {
    if (!stats) return;
    setWithdrawShares(formatUnits(BigInt(stats.lenderShares), 18));
  }

  return (
    <div className="card p-6 max-w-md">
      <div className="flex items-center gap-2 text-sm text-muted mb-4">
        <CoinsIcon className="w-4 h-4" /> Lending Vault — Supply
      </div>

      {!address ? (
        <button onClick={() => connect()} className="btn-primary w-full py-2.5 text-sm">
          Connect Wallet
        </button>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 mb-4">
            <Stat
              label="Your supplied"
              value={stats ? `${formatUnits(yourShareValue, borrowDecimals)}` : "—"}
            />
            <Stat
              label="Your shares"
              value={stats ? formatUnits(BigInt(stats.lenderShares), 18) : "—"}
            />
            <Stat
              label="Idle liquidity"
              value={stats ? formatUnits(idleLiquidity, borrowDecimals) : "—"}
            />
            <Stat
              label="Total outstanding debt"
              value={stats ? formatUnits(BigInt(stats.totalDebtPrincipal), borrowDecimals) : "—"}
            />
          </div>

          <div className="input-field p-3 mb-2">
            <p className="text-xs text-muted mb-1">Supply {borrowSymbol}</p>
            <input
              className="w-full bg-transparent outline-none text-lg text-foreground"
              placeholder="0.0"
              value={supplyAmount}
              onChange={(e) => setSupplyAmount(e.target.value)}
            />
          </div>
          <button
            onClick={handleSupply}
            disabled={!supplyAmount || pending === "Supply liquidity"}
            className="btn-primary w-full py-2 text-sm mb-3"
          >
            {pending === "Supply liquidity" ? "Confirming…" : "Supply"}
          </button>

          <div className="input-field p-3 mb-2">
            <div className="flex items-center justify-between mb-1">
              <p className="text-xs text-muted">Withdraw (shares)</p>
              <button onClick={fillMaxShares} className="text-xs text-muted underline hover:text-foreground">
                Max
              </button>
            </div>
            <input
              className="w-full bg-transparent outline-none text-lg text-foreground"
              placeholder="0.0"
              value={withdrawShares}
              onChange={(e) => setWithdrawShares(e.target.value)}
            />
          </div>
          <button
            onClick={handleWithdraw}
            disabled={!withdrawShares || pending === "Withdraw liquidity"}
            className="btn-primary w-full py-2 text-sm"
          >
            {pending === "Withdraw liquidity" ? "Confirming…" : "Withdraw"}
          </button>
          <p className="mt-2 text-xs text-muted">
            Withdraw reverts if idle liquidity can&apos;t cover it — capital currently lent out isn&apos;t
            withdrawable until borrowers repay.
          </p>
        </>
      )}

      {status && <p className="mt-3 text-xs text-muted break-all">{status}</p>}
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-muted">{label}</p>
      <p className="text-lg font-semibold text-foreground">{value}</p>
    </div>
  );
}
