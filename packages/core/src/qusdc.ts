import type { Address } from "viem";
import type { ChainClient } from "./chain.js";
import { QieForgeError } from "./errors.js";

const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "totalSupply",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export interface QusdcConfig {
  address: Address;
  decimals: number;
}

/**
 * QUSDC is documented at docs.stable.qie.digital as a 1:1 USDC-backed
 * receipt token, but — exactly like this portfolio's prior cred402
 * research found — its ERC-20 contract address was NOT independently
 * confirmed by this build either. QIE Forge therefore never hardcodes a
 * guessed address.
 *
 * Resolution order:
 *   1. Explicit `address`/`decimals` passed to the constructor.
 *   2. `QIE_FORGE_QUSDC_ADDRESS` / `QIE_FORGE_QUSDC_DECIMALS` env vars.
 *   3. Throws ASSET_NOT_CONFIGURED. No default is ever assumed.
 */
export function resolveQusdcConfig(explicit?: Partial<QusdcConfig>): QusdcConfig {
  const address = (explicit?.address ?? process.env.QIE_FORGE_QUSDC_ADDRESS) as
    | Address
    | undefined;
  const decimalsRaw = explicit?.decimals ?? process.env.QIE_FORGE_QUSDC_DECIMALS;

  if (!address) {
    throw new QieForgeError(
      "ASSET_NOT_CONFIGURED",
      "QUSDC's ERC-20 contract address is not independently confirmed by QIE Forge's own research. " +
        "Set QIE_FORGE_QUSDC_ADDRESS to a verified contract address (and QIE_FORGE_QUSDC_DECIMALS, " +
        "default 6) to enable QusdcClient. QIE Forge never guesses this value.",
    );
  }

  const decimals = decimalsRaw === undefined ? 6 : Number(decimalsRaw);
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 36) {
    throw new QieForgeError(
      "ASSET_NOT_CONFIGURED",
      `QIE_FORGE_QUSDC_DECIMALS must be a small non-negative integer, got "${decimalsRaw}".`,
    );
  }

  return { address, decimals };
}

export class QusdcClient {
  private readonly chain: ChainClient;
  readonly config: QusdcConfig;

  constructor(chain: ChainClient, config?: Partial<QusdcConfig>) {
    this.chain = chain;
    this.config = resolveQusdcConfig(config);
  }

  /** Confirms the configured address actually has deployed bytecode on the active network. */
  async verifyDeployed(): Promise<boolean> {
    return this.chain.isContractDeployed(this.config.address);
  }

  async balanceOf(holder: string): Promise<bigint> {
    return this.chain.readContract<bigint>({
      address: this.config.address,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [holder as Address],
    });
  }

  async totalSupply(): Promise<bigint> {
    return this.chain.readContract<bigint>({
      address: this.config.address,
      abi: ERC20_ABI,
      functionName: "totalSupply",
      args: [],
    });
  }
}
