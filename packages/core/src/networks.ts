import { QieForgeError } from "./errors.js";

export type QieNetworkName = "testnet" | "mainnet" | "demo";

export interface QieNetworkConfig {
  readonly name: QieNetworkName;
  readonly chainId: number;
  /** Default JSON-RPC endpoint. Always overridable — see resolveNetwork(). */
  readonly rpcUrl: string;
  /** Blockscout-style explorer origin for this network. */
  readonly explorerUrl: string;
  /** Blockscout REST API base (`/api`) on the same origin. */
  readonly explorerApiUrl: string;
  readonly nativeCurrencySymbol: string;
}

/**
 * Real, independently verified endpoints (verified live 2026-10-26 against
 * the actual QIE RPC/explorer, not copied from older docs without
 * re-checking):
 *
 * - Testnet chain ID 1983 confirmed via `eth_chainId` -> 0x7bf.
 * - Mainnet chain ID 1990 confirmed via `eth_chainId` -> 0x7c6.
 * - `rpc1testnet.qie.digital` (the URL documented in this portfolio's
 *   earlier QIE research and in cred402's docs) returned
 *   ECONNREFUSED on 2026-10-26 — it appears to have been retired/rotated.
 *   The working replacement found during this build is the testnet
 *   Blockscout explorer's own JSON-RPC proxy at
 *   `https://testnet.qie.digital/api/eth-rpc`, confirmed live (returned a
 *   real current block number). Because hosted RPC URLs on this chain have
 *   already moved once, QIE Forge NEVER hardcodes trust in a single
 *   endpoint without an override path — see resolveNetwork().
 * - `rpc1mainnet.qie.digital` confirmed live and returning real mainnet
 *   block data.
 */
const NETWORKS: Record<QieNetworkName, QieNetworkConfig> = {
  testnet: {
    name: "testnet",
    chainId: 1983,
    rpcUrl: "https://testnet.qie.digital/api/eth-rpc",
    explorerUrl: "https://testnet.qie.digital",
    explorerApiUrl: "https://testnet.qie.digital/api",
    nativeCurrencySymbol: "QIE",
  },
  mainnet: {
    name: "mainnet",
    chainId: 1990,
    rpcUrl: "https://rpc1mainnet.qie.digital",
    explorerUrl: "https://mainnet.qie.digital",
    explorerApiUrl: "https://mainnet.qie.digital/api",
    nativeCurrencySymbol: "QIE",
  },
  /**
   * NOT QIE Testnet or Mainnet. A disposable local-anvil devnet
   * (self-hosted, see packages/contracts/script/DeployDemo.s.sol) that
   * mirrors the real QIE Forge protocol so /swap and /vault never have to
   * show an empty state while the actual deployment waits on a funded QIE
   * deployer key (docs/STATUS.md). All tokens, prices, and liquidity here
   * are mock/demo data with zero real value. The frontend always labels
   * this clearly — see components/DemoBanner.tsx — so it is never
   * mistaken for live mainnet/testnet activity.
   */
  demo: {
    name: "demo",
    chainId: 31337,
    rpcUrl: "http://127.0.0.1:8545",
    explorerUrl: "",
    explorerApiUrl: "",
    nativeCurrencySymbol: "ETH",
  },
};

export interface ResolveNetworkOptions {
  /** Explicit RPC URL override. Takes precedence over env vars and defaults. */
  rpcUrl?: string;
}

/**
 * Resolve a network config, honoring environment overrides so operators can
 * always point at a different RPC without a code change — the same
 * "required/overridable, never silently wrong" posture used throughout this
 * portfolio's chain integrations.
 *
 * Env overrides:
 *   QIE_FORGE_TESTNET_RPC_URL
 *   QIE_FORGE_MAINNET_RPC_URL
 */
export function resolveNetwork(
  name: QieNetworkName,
  options: ResolveNetworkOptions = {},
): QieNetworkConfig {
  const base = NETWORKS[name];
  if (!base) {
    throw new QieForgeError(
      "UNSUPPORTED_NETWORK",
      `Unsupported QIE network "${name}". Supported: ${Object.keys(NETWORKS).join(", ")}`,
    );
  }

  const envVar =
    name === "testnet"
      ? process.env.QIE_FORGE_TESTNET_RPC_URL
      : name === "mainnet"
        ? process.env.QIE_FORGE_MAINNET_RPC_URL
        : process.env.QIE_FORGE_DEMO_RPC_URL;

  const rpcUrl = options.rpcUrl ?? envVar ?? base.rpcUrl;

  return { ...base, rpcUrl };
}

export function listNetworks(): QieNetworkConfig[] {
  return Object.values(NETWORKS);
}
