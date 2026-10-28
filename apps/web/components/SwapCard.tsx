"use client";

import { useEffect, useMemo, useState } from "react";
import { encodeFunctionData, parseUnits, formatUnits } from "viem";
import { useWallet } from "./WalletProvider";
import { ROUTER_ABI } from "@/lib/contracts";
import { getNetworkConfig } from "@/lib/config";
import { ensureAllowance, sendContractCall } from "@/lib/erc20Actions";
import { SwapIcon } from "./icons";

interface Token {
  symbol: string;
  address: `0x${string}`;
  decimals: number;
}

export function SwapCard({ tokens, routerAddress }: { tokens: Token[]; routerAddress: `0x${string}` }) {
  const { provider, address, connect } = useWallet();
  const chainId = getNetworkConfig().chainId;
  const [tokenInSymbol, setTokenInSymbol] = useState(tokens[0]?.symbol);
  const [tokenOutSymbol, setTokenOutSymbol] = useState(tokens[1]?.symbol ?? tokens[0]?.symbol);
  const [amountIn, setAmountIn] = useState("");
  const [quote, setQuote] = useState<string | undefined>(undefined);
  const [quoting, setQuoting] = useState(false);
  const [status, setStatus] = useState<string | undefined>(undefined);

  const tokenIn = tokens.find((t) => t.symbol === tokenInSymbol);
  const tokenOut = tokens.find((t) => t.symbol === tokenOutSymbol);

  const amountInBase = useMemo(() => {
    if (!tokenIn || !amountIn) return undefined;
    try {
      return parseUnits(amountIn, tokenIn.decimals);
    } catch {
      return undefined;
    }
  }, [amountIn, tokenIn]);

  useEffect(() => {
    if (!tokenIn || !tokenOut || !amountInBase || amountInBase === 0n) {
      return;
    }
    const controller = new AbortController();
    // Standard "fetch on dependency change" pattern: setQuoting(true) marks
    // loading state before the async request starts, setQuote happens
    // inside the .then() callback below, never synchronously. The stricter
    // react-hooks/set-state-in-effect rule flags this known-safe pattern.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setQuoting(true);
    const params = new URLSearchParams({ amountIn: amountInBase.toString() });
    params.append("path", tokenIn.address);
    params.append("path", tokenOut.address);
    fetch(`/api/quote?${params.toString()}`, { signal: controller.signal })
      .then((r) => r.json())
      .then((data) => {
        if (data.amounts) setQuote(data.amounts[data.amounts.length - 1]);
        else setQuote(undefined);
      })
      .catch(() => {})
      .finally(() => setQuoting(false));
    return () => controller.abort();
  }, [amountInBase, tokenIn, tokenOut]);

  async function handleSwap() {
    if (!provider || !address || !tokenIn || !tokenOut || !amountInBase || !quote) return;
    setStatus("Checking allowance…");
    try {
      const approved = await ensureAllowance(
        provider,
        tokenIn.address,
        address as `0x${string}`,
        routerAddress,
        amountInBase,
      );
      if (approved) setStatus("Approval sent, submitting swap…");

      const deadline = Math.floor(Date.now() / 1000) + 1800;
      const minOut = (BigInt(quote) * 99n) / 100n; // 1% slippage tolerance
      const swapData = encodeFunctionData({
        abi: ROUTER_ABI,
        functionName: "swapExactTokensForTokens",
        args: [amountInBase, minOut, [tokenIn.address, tokenOut.address], address as `0x${string}`, BigInt(deadline)],
      });
      const txHash = await sendContractCall(provider, address as `0x${string}`, routerAddress, swapData);
      setStatus(`Swap submitted: ${txHash}`);
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "Swap failed");
    }
  }

  return (
    <div className="card p-6 max-w-md">
      <div className="flex items-center gap-2 text-sm text-muted mb-4">
        <SwapIcon className="w-4 h-4" /> Swap
      </div>

      <div className="space-y-3">
        <TokenInput
          label="You pay"
          amount={amountIn}
          onAmountChange={setAmountIn}
          tokens={tokens}
          selected={tokenInSymbol}
          onSelect={setTokenInSymbol}
        />
        <TokenInput
          label="You receive"
          amount={tokenOut && quote && amountInBase ? formatUnits(BigInt(quote), tokenOut.decimals) : ""}
          readOnly
          tokens={tokens}
          selected={tokenOutSymbol}
          onSelect={setTokenOutSymbol}
        />
      </div>

      {quoting && <p className="mt-2 text-xs text-muted">Fetching live quote…</p>}

      <button
        onClick={() => (address ? handleSwap() : connect(chainId))}
        disabled={Boolean(address) && (!quote || !amountInBase)}
        className="btn-primary w-full mt-4 py-2.5 text-sm"
      >
        {address ? "Swap" : "Connect Wallet to Swap"}
      </button>

      {status && <p className="mt-3 text-xs text-muted break-all">{status}</p>}
    </div>
  );
}

function TokenInput({
  label,
  amount,
  onAmountChange,
  readOnly,
  tokens,
  selected,
  onSelect,
}: {
  label: string;
  amount: string;
  onAmountChange?: (v: string) => void;
  readOnly?: boolean;
  tokens: Token[];
  selected?: string;
  onSelect: (symbol: string) => void;
}) {
  return (
    <div className="input-field p-3">
      <p className="text-xs text-muted mb-1">{label}</p>
      <div className="flex items-center gap-2">
        <input
          className="flex-1 bg-transparent outline-none text-lg text-foreground"
          placeholder="0.0"
          value={amount}
          readOnly={readOnly}
          onChange={(e) => onAmountChange?.(e.target.value)}
        />
        <select
          value={selected}
          onChange={(e) => onSelect(e.target.value)}
          className="btn-ghost text-sm px-2 py-1 bg-transparent"
        >
          {tokens.map((t) => (
            <option key={t.symbol} value={t.symbol}>
              {t.symbol}
            </option>
          ))}
        </select>
      </div>
    </div>
  );
}
