import { QieForgeError } from "./errors.js";
import type { QieNetworkConfig } from "./networks.js";

/**
 * QIE already runs a real Blockscout-family explorer at testnet.qie.digital
 * / mainnet.qie.digital with REST + GraphQL APIs (confirmed live
 * 2026-10-26, including a `/api/eth-rpc` JSON-RPC proxy). QIE Forge does
 * NOT re-implement a block indexer — that would duplicate working
 * infrastructure. Instead this module is a thin, typed client over the
 * explorer's existing public REST API (Blockscout's v2 `/api/v2/*` surface)
 * so SDK/CLI users get one consistent interface instead of hand-rolling
 * fetches to a JSON shape they have to reverse-engineer themselves.
 */
export interface ExplorerAddressInfo {
  hash: string;
  isContract: boolean;
  isVerified: boolean | undefined;
  coinBalance: string | undefined;
}

export class ExplorerClient {
  constructor(private readonly network: QieNetworkConfig) {}

  private async fetchJson<T>(path: string): Promise<T> {
    const url = `${this.network.explorerApiUrl}${path}`;
    let res: Response;
    try {
      res = await fetch(url, { signal: AbortSignal.timeout(10_000) });
    } catch (err) {
      throw new QieForgeError(
        "EXPLORER_UNAVAILABLE",
        `Could not reach QIE ${this.network.name} explorer API at ${url}: ${(err as Error).message}`,
        { url },
      );
    }
    if (!res.ok) {
      throw new QieForgeError(
        "EXPLORER_UNAVAILABLE",
        `QIE ${this.network.name} explorer API returned HTTP ${res.status} for ${url}`,
        { url, status: res.status },
      );
    }
    return (await res.json()) as T;
  }

  /** Blockscout v2 address summary — includes verification + contract status. */
  async getAddress(address: string): Promise<ExplorerAddressInfo> {
    const data = await this.fetchJson<Record<string, unknown>>(`/v2/addresses/${address}`);
    return {
      hash: String(data.hash ?? address),
      isContract: Boolean(data.is_contract),
      isVerified:
        typeof data.is_verified === "boolean" ? (data.is_verified as boolean) : undefined,
      coinBalance:
        typeof data.coin_balance === "string" ? (data.coin_balance as string) : undefined,
    };
  }

  /** Raw pass-through to any Blockscout v2 endpoint, for callers who need a field this client doesn't model yet. */
  async getRaw(path: string): Promise<unknown> {
    return this.fetchJson(path);
  }

  addressUrl(address: string): string {
    return `${this.network.explorerUrl}/address/${address}`;
  }

  txUrl(txHash: string): string {
    return `${this.network.explorerUrl}/tx/${txHash}`;
  }
}
