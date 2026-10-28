import { getRouterAddress, getSwapTokens, getNetworkName } from "@/lib/config";
import { getPoolStats } from "@/lib/poolStats";
import { LiquidityCard } from "@/components/LiquidityCard";
import { PoolStatsBar } from "@/components/PoolStatsBar";
import { AlertIcon } from "@/components/icons";
import { DemoBanner } from "@/components/DemoBanner";

export const dynamic = "force-dynamic";

export default async function PoolPage() {
  const routerAddress = getRouterAddress();
  const tokens = getSwapTokens();
  const [tokenA, tokenB] = tokens;
  const stats = tokenA && tokenB ? await getPoolStats(tokenA.address, tokenB.address) : undefined;

  return (
    <div className="mx-auto max-w-5xl px-6 py-16">
      <h1 className="text-2xl font-semibold text-foreground mb-6">Pool</h1>
      {getNetworkName() === "demo" && <DemoBanner />}

      {routerAddress && tokenA && tokenB ? (
        <>
          {stats ? (
            <PoolStatsBar stats={stats} tokenA={tokenA} tokenB={tokenB} />
          ) : (
            <div className="card p-5 mb-6 flex items-start gap-3">
              <AlertIcon className="w-5 h-5 text-muted mt-0.5" />
              <p className="text-sm text-muted">
                No {tokenA.symbol}/{tokenB.symbol} pool exists yet — be the first to add liquidity below. The
                router creates the pair automatically on your first deposit.
              </p>
            </div>
          )}
          <LiquidityCard tokenA={tokenA} tokenB={tokenB} routerAddress={routerAddress} />
        </>
      ) : (
        <div className="card p-6 max-w-md flex items-start gap-3">
          <AlertIcon className="w-5 h-5 text-muted mt-0.5" />
          <p className="text-sm text-muted">
            No router/token configuration set for this network yet (
            <code className="text-xs">NEXT_PUBLIC_QIE_FORGE_ROUTER_ADDRESS</code> /{" "}
            <code className="text-xs">NEXT_PUBLIC_QIE_FORGE_SWAP_TOKENS</code>). The protocol itself is
            built and tested — see{" "}
            <a className="underline hover:text-foreground" href="https://github.com/caelum0x/qie-forge">
              the repo
            </a>{" "}
            — it just isn&apos;t deployed on this network yet.
          </p>
        </div>
      )}
    </div>
  );
}
