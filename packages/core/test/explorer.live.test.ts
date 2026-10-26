import { describe, expect, it } from "vitest";
import { ExplorerClient } from "../src/explorer.js";
import { resolveNetwork } from "../src/networks.js";

const LIVE = process.env.QIE_FORGE_RUN_LIVE_TESTS === "1";
const describeLive = LIVE ? describe : describe.skip;

describeLive("ExplorerClient (live Blockscout API)", () => {
  it("testnet: looks up the BTC oracle address and gets a real response shape", async () => {
    const explorer = new ExplorerClient(resolveNetwork("testnet"));
    const info = await explorer.getAddress("0x9E596d809a20A272c788726f592c0d1629755440");
    expect(info.hash.toLowerCase()).toBe("0x9e596d809a20a272c788726f592c0d1629755440");
  }, 20_000);

  it("mainnet: the BTC oracle address is reported as a contract", async () => {
    const explorer = new ExplorerClient(resolveNetwork("mainnet"));
    const info = await explorer.getAddress("0x9E596d809a20A272c788726f592c0d1629755440");
    expect(info.isContract).toBe(true);
  }, 20_000);

  it("builds correct explorer URLs without any network call", () => {
    const explorer = new ExplorerClient(resolveNetwork("testnet"));
    expect(explorer.addressUrl("0xabc")).toBe("https://testnet.qie.digital/address/0xabc");
    expect(explorer.txUrl("0xdef")).toBe("https://testnet.qie.digital/tx/0xdef");
  });
});
