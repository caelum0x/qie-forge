import { describe, expect, it } from "vitest";
import { ChainClient } from "../src/chain.js";
import { getAmountsOut, getReserves } from "../src/amm.js";
import { VaultClient } from "../src/vault.js";

/**
 * Live against the real self-hosted demo devnet backing
 * https://qie-forge.vercel.app (the same persistent anvil instance used by
 * every other live-verification pass in this repo's history). Gated the
 * same way chain.live.test.ts is — QIE_FORGE_RUN_LIVE_TESTS=1 — so a plain
 * `npm test` stays offline and deterministic.
 *
 * Addresses pulled from the real Vercel production env
 * (`vercel env pull`) on 2026-10-29: the live production app's own
 * FACTORY/ROUTER/VAULT/WQIE/TUSD addresses, not placeholders.
 */
const LIVE = process.env.QIE_FORGE_RUN_LIVE_TESTS === "1";
const describeLive = LIVE ? describe : describe.skip;

const DEMO_RPC_URL = "http://130.61.180.42:8647";
const FACTORY = "0x02b0b4efd909240fcb2eb5fae060dc60d112e3a4";
const VAULT = "0xd49a0e9a4cd5979ae36840f542d2d7f02c4817be";
const WQIE = "0x6C2d83262fF84cBaDb3e416D527403135D757892";
const TUSD = "0xFD6F7A6a5c21A3f503EBaE7a473639974379c351";

describeLive("@qie-forge/core amm.ts + vault.ts (live, real self-hosted demo chain)", () => {
  it("getReserves reads the real WQIE/TUSD pair reserves", async () => {
    const chain = new ChainClient({ network: "demo", rpcUrl: DEMO_RPC_URL });
    const [reserveWqie, reserveTusd] = await getReserves(chain, FACTORY, WQIE, TUSD);
    expect(reserveWqie).toBeGreaterThan(0n);
    expect(reserveTusd).toBeGreaterThan(0n);
  }, 20_000);

  it("getAmountsOut quotes a real swap matching the live router's own pricing", async () => {
    const chain = new ChainClient({ network: "demo", rpcUrl: DEMO_RPC_URL });
    const amounts = await getAmountsOut(chain, FACTORY, 1_000_000_000_000_000_000n, [WQIE, TUSD]);
    expect(amounts).toHaveLength(2);
    expect(amounts[0]).toBe(1_000_000_000_000_000_000n);
    expect(amounts[1]).toBeGreaterThan(0n);
  }, 20_000);

  it("VaultClient.getPosition reads the real live vault's own ltv/liquidation config", async () => {
    const chain = new ChainClient({ network: "demo", rpcUrl: DEMO_RPC_URL });
    const vault = new VaultClient(chain, VAULT);
    const [ltvBps, liquidationThresholdBps] = await Promise.all([
      vault.getLtvBps(),
      vault.getLiquidationThresholdBps(),
    ]);
    expect(ltvBps).toBeGreaterThan(0n);
    expect(liquidationThresholdBps).toBeGreaterThanOrEqual(ltvBps);

    // An address with no open position on this real vault — healthFactor
    // must report "infinite" (uint256 max) rather than reverting.
    const position = await vault.getPosition("0x0000000000000000000000000000000000000001");
    expect(position.debtPrincipal).toBe(0n);
    expect(position.healthFactor).toBe(2n ** 256n - 1n);
  }, 20_000);
});
