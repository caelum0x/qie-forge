import { resolveNetwork, type QieNetworkName } from "@qie-forge/core";

/**
 * All contract addresses here are deliberately env-driven with NO
 * hardcoded default — matching this project's fail-closed posture
 * everywhere else (QusdcClient, QieOracleAdapter). Nothing is deployed to
 * the live QIE testnet/mainnet yet (see docs/STATUS.md: blocked on a
 * funded deployer wallet, an owner/operator step). The UI reflects that
 * honestly — Swap/Vault show a clear "not deployed on this network yet"
 * state instead of pointing at a placeholder address.
 */

export function getNetworkName(): QieNetworkName {
  const value = process.env.NEXT_PUBLIC_QIE_FORGE_NETWORK;
  if (value === "mainnet") return "mainnet";
  if (value === "demo") return "demo";
  return "testnet";
}

export function getNetworkConfig() {
  return resolveNetwork(getNetworkName(), {
    rpcUrl: process.env.NEXT_PUBLIC_QIE_FORGE_RPC_URL || undefined,
  });
}

export function getFactoryAddress(): `0x${string}` | undefined {
  return (process.env.NEXT_PUBLIC_QIE_FORGE_FACTORY_ADDRESS as `0x${string}` | undefined) || undefined;
}

export function getRouterAddress(): `0x${string}` | undefined {
  return (process.env.NEXT_PUBLIC_QIE_FORGE_ROUTER_ADDRESS as `0x${string}` | undefined) || undefined;
}

export function getVaultAddress(): `0x${string}` | undefined {
  return (process.env.NEXT_PUBLIC_QIE_FORGE_VAULT_ADDRESS as `0x${string}` | undefined) || undefined;
}

/** Comma-separated `SYMBOL:address:decimals` list, e.g. "WQIE:0xabc...:18,TUSD:0xdef...:6". */
export function getSwapTokens(): { symbol: string; address: `0x${string}`; decimals: number }[] {
  const raw = process.env.NEXT_PUBLIC_QIE_FORGE_SWAP_TOKENS;
  if (!raw) return [];
  return raw
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const [symbol, address, decimals] = entry.split(":");
      return { symbol, address: address as `0x${string}`, decimals: Number(decimals || 18) };
    });
}
