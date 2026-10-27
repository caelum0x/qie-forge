import { AlertIcon } from "./icons";

/**
 * Shown only when NEXT_PUBLIC_QIE_FORGE_NETWORK="demo" — a self-hosted
 * local-anvil devnet (packages/contracts/script/DeployDemo.s.sol) seeded
 * with real liquidity and a real vault position, standing in for QIE
 * Testnet/Mainnet while the real deployment waits on a funded QIE deployer
 * key (docs/STATUS.md). Deliberately loud and unmissable: this must never
 * be confused with live QIE Testnet or Mainnet activity.
 */
export function DemoBanner() {
  return (
    <div className="mb-6 rounded-lg border border-amber-500/40 bg-amber-500/10 p-4 flex items-start gap-3">
      <AlertIcon className="w-5 h-5 text-amber-500 mt-0.5 shrink-0" />
      <div className="text-sm">
        <p className="font-medium text-amber-600 dark:text-amber-400">Local demo network — not QIE Testnet or Mainnet</p>
        <p className="text-muted mt-1">
          The real, compiled QieForge contracts (factory, router, oracle, vault) are deployed to a
          self-hosted anvil devnet and seeded with demo liquidity so you can try the real protocol
          end to end. Tokens, balances, and prices here are disposable demo data with zero real
          value. Once a funded QIE deployer key exists, this flips to a real Testnet/Mainnet
          deployment with no frontend code change — see{" "}
          <a className="underline hover:text-foreground" href="https://github.com/caelum0x/qie-forge/blob/main/docs/STATUS.md">
            docs/STATUS.md
          </a>
          .
        </p>
      </div>
    </div>
  );
}
