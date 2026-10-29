"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { encodeFunctionData, formatUnits, parseUnits } from "viem";
import { useWallet } from "./WalletProvider";
import { ROUTER_ABI } from "@/lib/contracts";
import { ensureAllowance, sendContractCall } from "@/lib/erc20Actions";
import { DropletIcon } from "./icons";

interface Token {
  symbol: string;
  address: `0x${string}`;
  decimals: number;
}

interface PoolPosition {
  pairAddress: `0x${string}`;
  token0: `0x${string}`;
  reserve0: string;
  reserve1: string;
  totalSupply: string;
  lpBalance: string;
}

/**
 * Liquidity provider UI for the AMM pair — `QieForgePair.mint()`/`burn()`
 * have existed since the first commit, and `QieForgeRouter.addLiquidity()`/
 * `removeLiquidity()` since the router shipped, but there was never a
 * frontend for either: `/swap` only ever called `swapExactTokensForTokens`.
 * Anyone wanting to actually become an LP and earn the 30bps swap fee had
 * no way to do so except raw contract calls — the same class of gap the
 * vault's borrow/repay/supply UI closed on 2026-10-28 for the lending side.
 */
export function LiquidityCard({
  tokenA,
  tokenB,
  routerAddress,
}: {
  tokenA: Token;
  tokenB: Token;
  routerAddress: `0x${string}`;
}) {
  const { provider, address, connect } = useWallet();
  const [position, setPosition] = useState<PoolPosition | undefined>(undefined);
  const [amountA, setAmountA] = useState("");
  const [amountB, setAmountB] = useState("");
  const [removeAmount, setRemoveAmount] = useState("");
  const [status, setStatus] = useState<string | undefined>(undefined);
  const [pending, setPending] = useState<string | undefined>(undefined);

  const refresh = useCallback(async () => {
    if (!address) return;
    const params = new URLSearchParams({ tokenA: tokenA.address, tokenB: tokenB.address, user: address });
    const res = await fetch(`/api/pool-position?${params.toString()}`);
    const data = await res.json();
    if (!data.error) setPosition(data);
    else setPosition(undefined);
  }, [address, tokenA.address, tokenB.address]);

  useEffect(() => {
    if (!address) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void refresh();
  }, [address, refresh]);

  const reserves = useMemo(() => {
    if (!position) return undefined;
    const isAToken0 = position.token0.toLowerCase() === tokenA.address.toLowerCase();
    const reserveA = BigInt(isAToken0 ? position.reserve0 : position.reserve1);
    const reserveB = BigInt(isAToken0 ? position.reserve1 : position.reserve0);
    return { reserveA, reserveB };
  }, [position, tokenA.address]);

  function handleAmountAChange(value: string) {
    setAmountA(value);
    if (!reserves || reserves.reserveA === 0n) return; // fresh pool: both amounts are free-form
    try {
      const amountABase = parseUnits(value || "0", tokenA.decimals);
      const amountBBase = (amountABase * reserves.reserveB) / reserves.reserveA;
      setAmountB(formatUnits(amountBBase, tokenB.decimals));
    } catch {
      // ignore partial/invalid input while typing
    }
  }

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

  function handleAddLiquidity() {
    if (!amountA || !amountB) return;
    runAction("Add liquidity", async () => {
      const amountABase = parseUnits(amountA, tokenA.decimals);
      const amountBBase = parseUnits(amountB, tokenB.decimals);
      await ensureAllowance(provider!, tokenA.address, address as `0x${string}`, routerAddress, amountABase);
      await ensureAllowance(provider!, tokenB.address, address as `0x${string}`, routerAddress, amountBBase);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800);
      const data = encodeFunctionData({
        abi: ROUTER_ABI,
        functionName: "addLiquidity",
        args: [
          tokenA.address,
          tokenB.address,
          amountABase,
          amountBBase,
          (amountABase * 99n) / 100n,
          (amountBBase * 99n) / 100n,
          address as `0x${string}`,
          deadline,
        ],
      });
      return sendContractCall(provider!, address as `0x${string}`, routerAddress, data);
    }).then(() => {
      setAmountA("");
      setAmountB("");
    });
  }

  function handleRemoveLiquidity() {
    if (!removeAmount || !position) return;
    runAction("Remove liquidity", async () => {
      const liquidity = parseUnits(removeAmount, 18);
      const totalSupply = BigInt(position.totalSupply);
      const expectedA = reserves && totalSupply > 0n ? (reserves.reserveA * liquidity) / totalSupply : 0n;
      const expectedB = reserves && totalSupply > 0n ? (reserves.reserveB * liquidity) / totalSupply : 0n;
      await ensureAllowance(
        provider!,
        position.pairAddress,
        address as `0x${string}`,
        routerAddress,
        liquidity,
      );
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800);
      const data = encodeFunctionData({
        abi: ROUTER_ABI,
        functionName: "removeLiquidity",
        args: [
          tokenA.address,
          tokenB.address,
          liquidity,
          (expectedA * 99n) / 100n,
          (expectedB * 99n) / 100n,
          address as `0x${string}`,
          deadline,
        ],
      });
      return sendContractCall(provider!, address as `0x${string}`, routerAddress, data);
    }).then(() => setRemoveAmount(""));
  }

  const lpBalanceDisplay = position ? formatUnits(BigInt(position.lpBalance), 18) : "—";

  return (
    <div className="card p-6 max-w-md">
      <div className="flex items-center gap-2 text-sm text-muted mb-4">
        <DropletIcon className="w-4 h-4" /> Liquidity — {tokenA.symbol}/{tokenB.symbol}
      </div>

      {!address ? (
        <button onClick={() => connect()} className="btn-primary w-full py-2.5 text-sm">
          Connect Wallet
        </button>
      ) : (
        <>
          <div className="mb-4">
            <p className="text-xs text-muted">Your LP tokens</p>
            <p className="text-lg font-semibold text-foreground">{lpBalanceDisplay}</p>
          </div>

          <p className="text-xs text-muted mb-2">Add liquidity</p>
          <AmountField
            label={`Deposit ${tokenA.symbol}`}
            amount={amountA}
            onAmountChange={handleAmountAChange}
          />
          <AmountField
            label={`Deposit ${tokenB.symbol}`}
            amount={amountB}
            onAmountChange={setAmountB}
          />
          <button
            onClick={handleAddLiquidity}
            disabled={!amountA || !amountB || pending === "Add liquidity"}
            className="btn-primary w-full py-2 text-sm mb-5"
          >
            {pending === "Add liquidity" ? "Confirming…" : "Add liquidity"}
          </button>

          <p className="text-xs text-muted mb-2">Remove liquidity</p>
          <AmountField label="LP tokens to remove" amount={removeAmount} onAmountChange={setRemoveAmount} />
          <button
            onClick={handleRemoveLiquidity}
            disabled={!removeAmount || !position || pending === "Remove liquidity"}
            className="btn-primary w-full py-2 text-sm"
          >
            {pending === "Remove liquidity" ? "Confirming…" : "Remove liquidity"}
          </button>
        </>
      )}

      {status && <p className="mt-3 text-xs text-muted break-all">{status}</p>}
    </div>
  );
}

function AmountField({
  label,
  amount,
  onAmountChange,
}: {
  label: string;
  amount: string;
  onAmountChange: (v: string) => void;
}) {
  return (
    <div className="input-field p-3 mb-2">
      <p className="text-xs text-muted mb-1">{label}</p>
      <input
        className="w-full bg-transparent outline-none text-lg text-foreground"
        placeholder="0.0"
        value={amount}
        onChange={(e) => onAmountChange(e.target.value)}
      />
    </div>
  );
}
