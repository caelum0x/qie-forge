import { describe, expect, it } from "vitest";
import { isLiquidatable, WAD, VaultClient, type VaultPosition } from "../src/vault.js";
import { ChainClient } from "../src/chain.js";
import { QieForgeError } from "../src/errors.js";

function position(overrides: Partial<VaultPosition> = {}): VaultPosition {
  return {
    collateral: 0n,
    debtPrincipal: 0n,
    lastAccrual: 0n,
    healthFactor: WAD,
    currentDebt: 0n,
    ...overrides,
  };
}

describe("isLiquidatable (mirrors VaultPosition.is_liquidatable in vault.py / vault.rs)", () => {
  it("is false when there is no debt, regardless of health factor", () => {
    expect(isLiquidatable(position({ debtPrincipal: 0n, healthFactor: 0n }))).toBe(false);
  });

  it("is false when health factor is at or above WAD", () => {
    expect(isLiquidatable(position({ debtPrincipal: 100n, healthFactor: WAD }))).toBe(false);
    expect(isLiquidatable(position({ debtPrincipal: 100n, healthFactor: WAD + 1n }))).toBe(false);
  });

  it("is true when there is debt and health factor is below WAD", () => {
    expect(isLiquidatable(position({ debtPrincipal: 100n, healthFactor: WAD - 1n }))).toBe(true);
  });
});

describe("VaultClient construction", () => {
  it("rejects an invalid vault address before making any network call", () => {
    const chain = new ChainClient({ network: "testnet" });
    expect(() => new VaultClient(chain, "not-an-address")).toThrowError(QieForgeError);
  });

  it("rejects an invalid user address before making any network call", async () => {
    const chain = new ChainClient({ network: "testnet" });
    const vault = new VaultClient(chain, "0x0000000000000000000000000000000000000001");
    await expect(vault.getPosition("not-an-address")).rejects.toThrowError(QieForgeError);
  });
});

describe("VaultClient pool-stats/liquidation-bonus surface (2026-10-29 parity gap)", () => {
  it("rejects an invalid user address in getLiquidationBonusBps before any network call", async () => {
    const chain = new ChainClient({ network: "testnet" });
    const vault = new VaultClient(chain, "0x0000000000000000000000000000000000000001");
    await expect(vault.getLiquidationBonusBps("not-an-address")).rejects.toThrowError(QieForgeError);
  });

  it("rejects an invalid user address in getLenderShares before any network call", async () => {
    const chain = new ChainClient({ network: "testnet" });
    const vault = new VaultClient(chain, "0x0000000000000000000000000000000000000001");
    await expect(vault.getLenderShares("not-an-address")).rejects.toThrowError(QieForgeError);
  });

  it("rejects an invalid user address in getPoolStats before any network call", async () => {
    const chain = new ChainClient({ network: "testnet" });
    const vault = new VaultClient(chain, "0x0000000000000000000000000000000000000001");
    await expect(vault.getPoolStats("not-an-address")).rejects.toThrowError(QieForgeError);
  });
});
