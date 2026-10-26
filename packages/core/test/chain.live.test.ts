import { describe, expect, it } from "vitest";
import { ChainClient } from "../src/chain.js";

/**
 * These tests hit the REAL QIE testnet and mainnet RPCs over the network.
 * They are gated behind QIE_FORGE_RUN_LIVE_TESTS=1 so a normal `npm test`
 * (CI-less, offline-friendly) run stays fast and deterministic, while
 * `npm run test:live` proves this SDK actually works against the live
 * chain — not fixtures. Floor values below are the real block numbers
 * observed during development on 2026-10-26; chains only grow, so a floor
 * check is honest and will never need lowering.
 */
const LIVE = process.env.QIE_FORGE_RUN_LIVE_TESTS === "1";
const describeLive = LIVE ? describe : describe.skip;

describeLive("ChainClient (live testnet + mainnet)", () => {
  it("testnet: reports chain ID 1983 and a block number past the 2026-10-26 floor", async () => {
    const client = new ChainClient({ network: "testnet" });
    const snapshot = await client.getSnapshot();
    expect(snapshot.chainId).toBe(1983);
    expect(snapshot.blockNumber).toBeGreaterThan(9_000_000n);
  }, 20_000);

  it("mainnet: reports chain ID 1990 and a block number past the 2026-10-26 floor", async () => {
    const client = new ChainClient({ network: "mainnet" });
    const snapshot = await client.getSnapshot();
    expect(snapshot.chainId).toBe(1990);
    expect(snapshot.blockNumber).toBeGreaterThan(11_000_000n);
  }, 20_000);

  it("testnet: a random EOA address has no deployed bytecode", async () => {
    const client = new ChainClient({ network: "testnet" });
    const isContract = await client.isContractDeployed(
      "0x0000000000000000000000000000000000000001",
    );
    expect(isContract).toBe(false);
  }, 20_000);

  it("rejects an invalid address before making any network call", async () => {
    const client = new ChainClient({ network: "testnet" });
    await expect(client.getBalance("not-an-address")).rejects.toThrow(/valid EVM address/);
  });
});
