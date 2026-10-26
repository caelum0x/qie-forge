import {
  type Address,
  type Block,
  type PublicClient,
  createPublicClient,
  defineChain,
  http,
  isAddress,
} from "viem";
import { QieForgeError } from "./errors.js";
import { type QieNetworkConfig, type QieNetworkName, resolveNetwork } from "./networks.js";

export interface ChainClientOptions {
  network: QieNetworkName;
  rpcUrl?: string;
  /** Request timeout in ms. Defaults to 10s — fails loudly rather than hanging. */
  timeoutMs?: number;
}

export interface ChainSnapshot {
  network: QieNetworkName;
  chainId: number;
  blockNumber: bigint;
  blockHash: string;
  timestamp: bigint;
  gasPrice: bigint;
}

/**
 * Thin, typed wrapper around QIE's EVM JSON-RPC surface. QIE is Cosmos-SDK
 * consensus underneath but exposes standard `eth_*` methods, so this reuses
 * viem's battle-tested EVM client rather than hand-rolling JSON-RPC framing.
 */
export class ChainClient {
  readonly config: QieNetworkConfig;
  private readonly client: PublicClient;

  constructor(options: ChainClientOptions) {
    this.config = resolveNetwork(options.network, { rpcUrl: options.rpcUrl });

    const chain = defineChain({
      id: this.config.chainId,
      name: `qie-${this.config.name}`,
      nativeCurrency: {
        name: "QIE",
        symbol: this.config.nativeCurrencySymbol,
        decimals: 18,
      },
      rpcUrls: {
        default: { http: [this.config.rpcUrl] },
      },
    });

    this.client = createPublicClient({
      chain,
      transport: http(this.config.rpcUrl, {
        timeout: options.timeoutMs ?? 10_000,
      }),
    });
  }

  /** Confirms the RPC is reachable AND reports the chain ID it actually serves. */
  async verifyChainId(): Promise<number> {
    try {
      const id = await this.client.getChainId();
      if (id !== this.config.chainId) {
        throw new QieForgeError(
          "INVALID_RESPONSE",
          `RPC at ${this.config.rpcUrl} returned chain ID ${id}, expected ${this.config.chainId} (${this.config.name}). Refusing to proceed on a mismatched network.`,
          { expected: this.config.chainId, actual: id, rpcUrl: this.config.rpcUrl },
        );
      }
      return id;
    } catch (err) {
      if (err instanceof QieForgeError) throw err;
      throw new QieForgeError(
        "NETWORK_UNREACHABLE",
        `Could not reach QIE ${this.config.name} RPC at ${this.config.rpcUrl}: ${(err as Error).message}`,
        { rpcUrl: this.config.rpcUrl, cause: String(err) },
      );
    }
  }

  async getSnapshot(): Promise<ChainSnapshot> {
    const [chainId, block, gasPrice] = await Promise.all([
      this.verifyChainId(),
      this.client.getBlock(),
      this.client.getGasPrice(),
    ]);

    return {
      network: this.config.name,
      chainId,
      blockNumber: block.number ?? 0n,
      blockHash: block.hash ?? "0x",
      timestamp: block.timestamp,
      gasPrice,
    };
  }

  async getBlockByNumber(blockNumber: bigint): Promise<Block> {
    return this.client.getBlock({ blockNumber });
  }

  async getBalance(address: string): Promise<bigint> {
    this.assertAddress(address);
    return this.client.getBalance({ address: address as Address });
  }

  /** Raw deployed bytecode at an address — "0x" means no contract is deployed there. */
  async getCode(address: string): Promise<`0x${string}`> {
    this.assertAddress(address);
    const code = await this.client.getCode({ address: address as Address });
    return code ?? "0x";
  }

  async isContractDeployed(address: string): Promise<boolean> {
    const code = await this.getCode(address);
    return code !== "0x" && code.length > 2;
  }

  readContract<T>(params: Parameters<PublicClient["readContract"]>[0]): Promise<T> {
    return this.client.readContract(params) as Promise<T>;
  }

  get publicClient(): PublicClient {
    return this.client;
  }

  private assertAddress(address: string): void {
    if (!isAddress(address)) {
      throw new QieForgeError("INVALID_ADDRESS", `"${address}" is not a valid EVM address`, {
        address,
      });
    }
  }
}
