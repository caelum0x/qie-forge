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
 *
 * Found 2026-10-29 (later pass): even after the above, this SDK's vault
 * surface only ever mirrored the ltvBps/liquidationThresholdBps feature
 * set vault.py/vault.rs shipped on 2026-10-27 — it never picked up the
 * lending-pool-level data (totalAssets/totalReserves/protocolReserves/
 * borrowCap/reserveFactorBps/totalLenderShares/lenderShares) or the
 * severity-scaled `liquidationBonusBpsFor` the vault contract itself
 * grew across the same day's later passes. apps/web's own
 * `/api/vault-position` route (see apps/web/app/api/vault-position/
 * route.ts) already reads every one of these real on-chain fields to
 * power the live LendCard/VaultCard UI, and scripts/liquidation-bot-
 * demo.mjs reimplements a raw eth_call for the bonus instead of using
 * this SDK at all — proof the published SDK (the one `@qie-forge/cli`
 * and any real third-party integrator would actually use) was missing
 * exactly the data a lending dashboard or liquidation bot needs. Closed
 * here with `getPoolStats`/`getLiquidationBonusBps`, field-for-field
 * matching the frontend route's own response shape.
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
  {
    type: "function",
    name: "liquidationBonusBpsFor",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalAssets",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalReserves",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "protocolReserves",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalDebtPrincipal",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "borrowCap",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "reserveFactorBps",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalLenderShares",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "lenderShares",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
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

/**
 * Lending-pool-level stats, independent of any one borrower's position —
 * field-for-field the same shape apps/web/app/api/vault-position/
 * route.ts already returns to power LendCard/VaultCard, now readable
 * through the published SDK instead of only via that bespoke Next.js
 * route.
 */
export interface VaultPoolStats {
  totalAssets: bigint;
  totalReserves: bigint;
  protocolReserves: bigint;
  totalDebtPrincipal: bigint;
  borrowCap: bigint;
  reserveFactorBps: bigint;
  totalLenderShares: bigint;
  /** This caller's own lender share balance; 0n if `user` is omitted. */
  lenderShares: bigint;
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

  /**
   * The severity-scaled liquidation bonus (bps) `user`'s position would
   * pay a liquidator right now — see `QieForgeVault.liquidationBonusBpsFor`.
   * Returns the flat base bonus for a healthy/debt-free position, matching
   * the contract's own non-reverting behavior on that path.
   */
  async getLiquidationBonusBps(user: string): Promise<bigint> {
    const account = assertAddress(user);
    return this.chain.readContract<bigint>({
      address: this.vaultAddress,
      abi: VAULT_ABI,
      functionName: "liquidationBonusBpsFor",
      args: [account],
    });
  }

  /**
   * This lender's own share balance. 0n for any address that has never
   * supplied, or whose shares were retired by a full bad-debt-wipeout
   * epoch bump (see QieForgeVault.sol's `lenderShares` doc comment) —
   * the contract's own getter already encodes that, this just exposes it.
   */
  async getLenderShares(user: string): Promise<bigint> {
    const account = assertAddress(user);
    return this.chain.readContract<bigint>({
      address: this.vaultAddress,
      abi: VAULT_ABI,
      functionName: "lenderShares",
      args: [account],
    });
  }

  /**
   * Pool-level lending stats, independent of any one borrower's own
   * position — the same real on-chain reads apps/web's `/api/vault-
   * position` route already does for the live LendCard/VaultCard UI,
   * now available through this SDK. Pass `user` to also get that
   * lender's own share balance; omit it to get pool-wide stats only.
   */
  async getPoolStats(user?: string): Promise<VaultPoolStats> {
    const account = user === undefined ? undefined : assertAddress(user);
    const [
      totalAssets,
      totalReserves,
      protocolReserves,
      totalDebtPrincipal,
      borrowCap,
      reserveFactorBps,
      totalLenderShares,
      lenderShares,
    ] = await Promise.all([
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "totalAssets",
        args: [],
      }),
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "totalReserves",
        args: [],
      }),
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "protocolReserves",
        args: [],
      }),
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "totalDebtPrincipal",
        args: [],
      }),
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "borrowCap",
        args: [],
      }),
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "reserveFactorBps",
        args: [],
      }),
      this.chain.readContract<bigint>({
        address: this.vaultAddress,
        abi: VAULT_ABI,
        functionName: "totalLenderShares",
        args: [],
      }),
      account === undefined
        ? Promise.resolve(0n)
        : this.chain.readContract<bigint>({
            address: this.vaultAddress,
            abi: VAULT_ABI,
            functionName: "lenderShares",
            args: [account],
          }),
    ]);

    return {
      totalAssets,
      totalReserves,
      protocolReserves,
      totalDebtPrincipal,
      borrowCap,
      reserveFactorBps,
      totalLenderShares,
      lenderShares,
    };
  }
}
