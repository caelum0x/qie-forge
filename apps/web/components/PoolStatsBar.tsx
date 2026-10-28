import { formatUnits } from "viem";
import type { PoolStats } from "@/lib/poolStats";
import { DropletIcon } from "./icons";

interface Token {
  symbol: string;
  address: `0x${string}`;
  decimals: number;
}

/**
 * Always-visible AMM pool stats for `/pool` — reserves of each token and
 * total LP supply. Rendered server-side, no wallet connection required,
 * same posture as `VaultPoolStatsBar` on `/vault` and the homepage's
 * network/oracle cards: a hackathon judge reviewing the live site without
 * a browser wallet extension should still see the real pool, not an empty
 * "Connect Wallet" screen.
 */
export function PoolStatsBar({ stats, tokenA, tokenB }: { stats: PoolStats; tokenA: Token; tokenB: Token }) {
  const reserveA = stats.token0.toLowerCase() === tokenA.address.toLowerCase() ? stats.reserve0 : stats.reserve1;
  const reserveB = stats.token0.toLowerCase() === tokenA.address.toLowerCase() ? stats.reserve1 : stats.reserve0;

  return (
    <div className="card p-5 mb-6 grid grid-cols-2 sm:grid-cols-3 gap-4">
      <Stat
        icon
        label={`${tokenA.symbol} reserve`}
        value={`${formatUnits(BigInt(reserveA), tokenA.decimals)} ${tokenA.symbol}`}
      />
      <Stat
        label={`${tokenB.symbol} reserve`}
        value={`${formatUnits(BigInt(reserveB), tokenB.decimals)} ${tokenB.symbol}`}
      />
      <Stat label="LP tokens outstanding" value={formatUnits(BigInt(stats.totalSupply), 18)} />
    </div>
  );
}

function Stat({ icon, label, value }: { icon?: boolean; label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-muted flex items-center gap-1">
        {icon && <DropletIcon className="w-3.5 h-3.5" />} {label}
      </p>
      <p className="mt-1 text-lg font-semibold text-foreground break-all">{value}</p>
    </div>
  );
}
