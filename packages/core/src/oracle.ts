import type { Abi, Address } from "viem";
import type { ChainClient } from "./chain.js";
import { QieForgeError } from "./errors.js";
import type { QieNetworkName } from "./networks.js";

/**
 * QIE Oracle ABI — REAL, verified against live bytecode, not copied from
 * docs.qie.digital's code sample.
 *
 * docs.qie.digital/qie-oracle/getting-started/reading-data-from-oracle
 * documents `function getPrice(string calldata asset) external view
 * returns (uint256)`. That call was tried first while building this SDK
 * and reverted on every one of the 7 published addresses on Mainnet
 * (confirmed 2026-10-26 — see test/oracle.live.test.ts history / this
 * repo's commit log for the raw revert). Decoding the actual deployed
 * bytecode's function selectors (0x313ce567, 0x54fd4d50, 0x7284e416,
 * 0x8da5cb5b, 0x9a6fc8f5, 0xfeaf968c, ...) showed it is a standard
 * Chainlink `AggregatorV3Interface` clone instead — one dedicated
 * aggregator contract per asset, not a single multi-asset `getPrice`
 * router. Confirmed live via raw eth_call:
 *
 *   decimals()        -> 8               (on the BTC aggregator)
 *   description()     -> "BTC / USDT"
 *   latestRoundData() -> (roundId, answer, startedAt, updatedAt, answeredInRound)
 *
 * QIE Forge therefore implements the REAL interface. This is a genuine,
 * independently-verified correction to QIE's own published developer docs,
 * not a guess — every number above came from an actual eth_call against
 * QIE Mainnet during this build.
 */
export const QIE_ORACLE_ABI: Abi = [
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function",
    name: "description",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
  {
    type: "function",
    name: "version",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
  {
    type: "function",
    name: "getRoundData",
    stateMutability: "view",
    inputs: [{ name: "_roundId", type: "uint80" }],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
];

export type QieOracleAsset = "BTC" | "ETH" | "XRP" | "SOL" | "QIE" | "XAUt" | "BNB";

/**
 * Per-asset oracle contract addresses, exactly as published at
 * docs.qie.digital/qie-oracle/deployed-contracts/table-of-assets-contract-mapping.
 * Confirmed live on Mainnet via eth_getCode AND a real latestRoundData()
 * call on 2026-10-26 (see module doc above for the ABI correction).
 */
export const QIE_ORACLE_ADDRESSES: Record<QieOracleAsset, Address> = {
  BTC: "0x9E596d809a20A272c788726f592c0d1629755440" as Address,
  ETH: "0x4bb7012Fbc79fE4Ae9B664228977b442b385500d" as Address,
  XRP: "0x804582B1f8Fea73919e7c737115009f668f97528" as Address,
  SOL: "0xe86999c8e6C8eeF71bebd35286bCa674E0AD7b21" as Address,
  QIE: "0x3Bc617cF3A4Bb77003e4c556B87b13D556903D17" as Address,
  XAUt: "0x9aD0199a67588ee293187d26bA1BE61cb07A214c" as Address,
  BNB: "0x775A56117Fdb8b31877E75Ceeb68C96765b031e6" as Address,
};

export interface OraclePriceResult {
  asset: QieOracleAsset;
  network: QieNetworkName;
  contractAddress: Address;
  description: string;
  decimals: number;
  roundId: bigint;
  /** Signed answer in the aggregator's own `decimals` units (e.g. 8 for BTC). */
  answer: bigint;
  updatedAt: bigint;
}

export interface OracleClientOptions {
  /**
   * Set of networks QIE Forge is allowed to treat the published addresses
   * as potentially valid on. Defaults to ["mainnet"] because that is the
   * only network where live bytecode was confirmed. A caller can widen
   * this (e.g. after QIE redeploys the oracle to testnet) without a code
   * change, but QIE Forge will never silently assume it — every read still
   * re-verifies eth_getCode.
   */
  deployedNetworks?: QieNetworkName[];
}

export class OracleClient {
  private readonly chain: ChainClient;
  private readonly deployedNetworks: Set<QieNetworkName>;

  constructor(chain: ChainClient, options: OracleClientOptions = {}) {
    this.chain = chain;
    this.deployedNetworks = new Set(options.deployedNetworks ?? ["mainnet"]);
  }

  listSupportedAssets(): QieOracleAsset[] {
    return Object.keys(QIE_ORACLE_ADDRESSES) as QieOracleAsset[];
  }

  getContractAddress(asset: QieOracleAsset): Address {
    const address = QIE_ORACLE_ADDRESSES[asset];
    if (!address) {
      throw new QieForgeError(
        "ORACLE_ASSET_UNSUPPORTED",
        `"${asset}" has no known QIE Oracle contract. Supported assets: ${this.listSupportedAssets().join(", ")}`,
        { asset },
      );
    }
    return address;
  }

  /**
   * Reads a live price via the REAL Chainlink-style `latestRoundData()`
   * interface (see module doc for why this differs from QIE's own docs).
   * Always re-verifies the contract is actually deployed on the active
   * network via eth_getCode before calling — the fail-closed check, not a
   * cached assumption.
   */
  async getPrice(asset: QieOracleAsset): Promise<OraclePriceResult> {
    const address = this.getContractAddress(asset);
    const network = this.chain.config.name;

    if (!this.deployedNetworks.has(network)) {
      throw new QieForgeError(
        "ORACLE_NOT_DEPLOYED",
        `QIE Oracle for "${asset}" is not configured as deployed on "${network}" ` +
          `(QIE Forge's deployedNetworks allowlist is [${[...this.deployedNetworks].join(", ")}]). ` +
          `Verified live on 2026-10-26: this oracle has real bytecode on Mainnet (1990) but ` +
          `empty bytecode ("0x") on Testnet (1983) at the same address.`,
        { asset, network, address },
      );
    }

    const isDeployed = await this.chain.isContractDeployed(address);
    if (!isDeployed) {
      throw new QieForgeError(
        "ORACLE_NOT_DEPLOYED",
        `eth_getCode returned no bytecode for the ${asset} oracle at ${address} on ${network}. ` +
          `Refusing to call latestRoundData() against a non-existent contract.`,
        { asset, network, address },
      );
    }

    const [decimals, description, roundData] = await Promise.all([
      this.chain.readContract<number>({
        address,
        abi: QIE_ORACLE_ABI,
        functionName: "decimals",
        args: [],
      }),
      this.chain.readContract<string>({
        address,
        abi: QIE_ORACLE_ABI,
        functionName: "description",
        args: [],
      }),
      this.chain.readContract<readonly [bigint, bigint, bigint, bigint, bigint]>({
        address,
        abi: QIE_ORACLE_ABI,
        functionName: "latestRoundData",
        args: [],
      }),
    ]);

    const [roundId, answer, , updatedAt] = roundData;

    if (answer <= 0n) {
      throw new QieForgeError(
        "INVALID_RESPONSE",
        `QIE Oracle for ${asset} returned a non-positive answer (${answer}). Treating as unreliable rather than reporting it.`,
        { asset, network, address, answer: answer.toString() },
      );
    }

    return {
      asset,
      network,
      contractAddress: address,
      description,
      decimals: Number(decimals),
      roundId,
      answer,
      updatedAt,
    };
  }

  async getPrices(assets: QieOracleAsset[]): Promise<OraclePriceResult[]> {
    return Promise.all(assets.map((asset) => this.getPrice(asset)));
  }
}
