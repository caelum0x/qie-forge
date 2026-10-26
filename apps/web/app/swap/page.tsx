import { getRouterAddress, getSwapTokens } from "@/lib/config";
import { SwapCard } from "@/components/SwapCard";
import { AlertIcon } from "@/components/icons";

export default function SwapPage() {
  const routerAddress = getRouterAddress();
  const tokens = getSwapTokens();

  return (
    <div className="mx-auto max-w-5xl px-6 py-16">
      <h1 className="text-2xl font-semibold text-foreground mb-6">Swap</h1>

      {routerAddress && tokens.length >= 2 ? (
        <SwapCard tokens={tokens} routerAddress={routerAddress} />
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
