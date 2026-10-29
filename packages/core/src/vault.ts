import { isAddress, type Address } from "viem";
import type { ChainClient } from "./chain.js";
import { QieForgeError } from "./errors.js";

/**
 * Read-only client for a deployed QieForgeVault — mirrors the vault's real
 * ABI (packages/contracts/src/vault/QieForgeVault.sol) and
 * packages/python/qie_forge/vault.py / packages/rust/src/vault.rs
 * field-for-field. No write/borrow/repay methods are included here
 * deliberately: this SDK builds unsigned transactions (see amm.ts's
 * `buildSwapExactTokensForTokensTx` pattern) rather than ever holding or
 * using a private key itself.
 *
 * This was the same cross-SDK parity gap amm.ts closes: Python and Rust
 * both shipped a `VaultClient` on 2026-10-27, @qie-forge/core never did.
 */

export const VAULT_ABI = [
  {
    type: "function",
    name: "positions",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [
      { name: "collateral", type: "uint128" },
      { name: "debtPrincipal", type: "uint128" },
      { name: "lastAccrual", type: "uint64" },
    ],
  },
  {
    type: "function",
    name: "healthFactor",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "currentDebt",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "ltvBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "liquidationThresholdBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

/** 1e18 — healthFactor is WAD-scaled; a position is liquidatable below this. */
export const WAD = 1_000_000_000_000_000_000n;

export interface VaultPosition {
  collateral: bigint;
  debtPrincipal: bigint;
  lastAccrual: bigint;
  healthFactor: bigint;
  currentDebt: bigint;
}

/** Mirrors `VaultPosition.is_liquidatable` in the Python/Rust SDKs. */
export function isLiquidatable(position: VaultPosition): boolean {
  return position.debtPrincipal > 0n && position.healthFactor < WAD;
}

function assertAddress(address: string): Address {
  if (!isAddress(address)) {
    throw new QieForgeError("INVALID_ADDRESS", `"${address}" is not a valid EVM address`, { address });
  }
  return address as Address;
}

export class VaultClient {
  private readonly chain: ChainClient;
  readonly vaultAddress: Address;

  constructor(chain: ChainClient, vaultAddress: string) {
    this.chain = chain;
    this.vaultAddress = assertAddress(vaultAddress);
  }

  async getPosition(user: string): Promise<VaultPosition> {
    const account = assertAddress(user);
    const [[collateral, debtPrincipal, lastAccrual], healthFactor, currentDebt] = await Promise.all([
      this.chain.readContract<readonly [bigint, bigint, bigint]>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "positions",
        args: [account],
      }),
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "healthFactor",
        args: [account],
      }),
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "currentDebt",
        args: [account],
      }),
    ]);

    return { collateral, debtPrincipal, lastAccrual, healthFactor, currentDebt };
  }

  async getLtvBps(): Promise<bigint> {
    return this.chain.readContract<bigint>({
      address: this.vaultAddress,
      abi: VAULT_ABI,
      functionName: "ltvBps",
      args: [],
    });
  }

  async getLiquidationThresholdBps(): Promise<bigint> {
    return this.chain.readContract<bigint>({
      address: this.vaultAddress,
      abi: VAULT_ABI,
      functionName: "liquidationThresholdBps",
      args: [],
    });
  }
}
