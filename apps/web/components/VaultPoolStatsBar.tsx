import { formatUnits } from "viem";
import type { VaultPoolStats } from "@/lib/vaultStats";
import { CoinsIcon } from "./icons";

/**
 * Always-visible pool-level stats for `/vault` — TVL, outstanding debt,
 * idle liquidity, utilization, lender count proxy (total shares). Rendered
 * server-side, with NO wallet connection required, same honest-live-data
 * posture as the homepage's network/oracle cards and `/swap`'s quote box.
 *
 * Deliberately separate from `VaultCard`/`LendCard`'s own per-user stats
 * (collateral, debt, health factor, your shares) — those genuinely need a
 * connected address. These four numbers do not, and gating them behind
 * "Connect Wallet" (the state before this fix) meant anyone without a
 * browser wallet extension saw nothing at all on `/vault`.
 */
export function VaultPoolStatsBar({
  stats,
  borrowDecimals,
  borrowSymbol,
}: {
  stats: VaultPoolStats;
  borrowDecimals: number;
  borrowSymbol: string;
}) {
  const totalAssets = BigInt(stats.totalAssets);
  const totalDebtPrincipal = BigInt(stats.totalDebtPrincipal);
  const idleLiquidity = totalAssets >= totalDebtPrincipal ? totalAssets - totalDebtPrincipal : 0n;
  const utilizationBps = totalAssets > 0n ? (totalDebtPrincipal * 10000n) / totalAssets : 0n;

  return (
    <div className="card p-5 mb-6 grid grid-cols-2 sm:grid-cols-4 gap-4">
      <Stat
        icon
        label="Total value locked"
        value={`${formatUnits(totalAssets, borrowDecimals)} ${borrowSymbol}`}
      />
      <Stat label="Idle liquidity" value={`${formatUnits(idleLiquidity, borrowDecimals)} ${borrowSymbol}`} />
      <Stat
        label="Outstanding debt"
        value={`${formatUnits(totalDebtPrincipal, borrowDecimals)} ${borrowSymbol}`}
      />
      <Stat label="Utilization" value={`${(Number(utilizationBps) / 100).toFixed(2)}%`} />
    </div>
  );
}

function Stat({ icon, label, value }: { icon?: boolean; label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-muted flex items-center gap-1">
        {icon && <CoinsIcon className="w-3.5 h-3.5" />} {label}
      </p>
      <p className="mt-1 text-lg font-semibold text-foreground break-all">{value}</p>
    </div>
  );
}
