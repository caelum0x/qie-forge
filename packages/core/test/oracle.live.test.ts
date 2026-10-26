import { describe, expect, it } from "vitest";
import { ChainClient } from "../src/chain.js";
import { OracleClient } from "../src/oracle.js";
import { QieForgeError } from "../src/errors.js";

const LIVE = process.env.QIE_FORGE_RUN_LIVE_TESTS === "1";
const describeLive = LIVE ? describe : describe.skip;

describeLive("OracleClient (live)", () => {
  it("mainnet: getPrice(BTC) returns a real positive on-chain price", async () => {
    const chain = new ChainClient({ network: "mainnet" });
    const oracle = new OracleClient(chain, { deployedNetworks: ["mainnet"] });
    const result = await oracle.getPrice("BTC");
    expect(result.network).toBe("mainnet");
    expect(result.rawPrice).toBeGreaterThan(0n);
  }, 20_000);

  it("mainnet: getPrice(QIE) returns a real positive on-chain price", async () => {
    const chain = new ChainClient({ network: "mainnet" });
    const oracle = new OracleClient(chain, { deployedNetworks: ["mainnet"] });
    const result = await oracle.getPrice("QIE");
    expect(result.rawPrice).toBeGreaterThan(0n);
  }, 20_000);

  it("testnet: fails closed with ORACLE_NOT_DEPLOYED instead of guessing a price", async () => {
    const chain = new ChainClient({ network: "testnet" });
    // deployedNetworks explicitly includes testnet here to prove the SECOND
    // layer of defense (the live eth_getCode check) also catches it, not
    // just the allowlist.
    const oracle = new OracleClient(chain, { deployedNetworks: ["testnet"] });
    await expect(oracle.getPrice("BTC")).rejects.toMatchObject({
      code: "ORACLE_NOT_DEPLOYED",
    });
  }, 20_000);

  it("testnet: the allowlist alone (default) also blocks it without any network call succeeding silently", async () => {
    const chain = new ChainClient({ network: "testnet" });
    const oracle = new OracleClient(chain); // default deployedNetworks = ["mainnet"]
    let caught: unknown;
    try {
      await oracle.getPrice("ETH");
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(QieForgeError);
    expect((caught as QieForgeError).code).toBe("ORACLE_NOT_DEPLOYED");
  });

  it("rejects an unsupported asset symbol before any network call", async () => {
    const chain = new ChainClient({ network: "mainnet" });
    const oracle = new OracleClient(chain);
    await expect(oracle.getPrice("DOGE" as never)).rejects.toMatchObject({
      code: "ORACLE_ASSET_UNSUPPORTED",
    });
  });
});
