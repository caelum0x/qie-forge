import { describe, expect, it, beforeEach, afterEach } from "vitest";
import { listNetworks, resolveNetwork } from "../src/networks.js";
import { QieForgeError } from "../src/errors.js";

describe("networks", () => {
  const ORIGINAL_ENV = { ...process.env };

  beforeEach(() => {
    delete process.env.QIE_FORGE_TESTNET_RPC_URL;
    delete process.env.QIE_FORGE_MAINNET_RPC_URL;
  });

  afterEach(() => {
    process.env = { ...ORIGINAL_ENV };
  });

  it("lists exactly testnet (1983) and mainnet (1990)", () => {
    const nets = listNetworks();
    const byName = Object.fromEntries(nets.map((n) => [n.name, n]));
    expect(byName.testnet.chainId).toBe(1983);
    expect(byName.mainnet.chainId).toBe(1990);
  });

  it("resolves default RPC URLs when no override is set", () => {
    const testnet = resolveNetwork("testnet");
    expect(testnet.rpcUrl).toBe("https://testnet.qie.digital/api/eth-rpc");

    const mainnet = resolveNetwork("mainnet");
    expect(mainnet.rpcUrl).toBe("https://rpc1mainnet.qie.digital");
  });

  it("an explicit rpcUrl option always wins over env and defaults", () => {
    process.env.QIE_FORGE_TESTNET_RPC_URL = "https://env-override.example/";
    const resolved = resolveNetwork("testnet", { rpcUrl: "https://explicit.example/" });
    expect(resolved.rpcUrl).toBe("https://explicit.example/");
  });

  it("falls back to the env var when no explicit override is given", () => {
    process.env.QIE_FORGE_MAINNET_RPC_URL = "https://env-mainnet.example/";
    const resolved = resolveNetwork("mainnet");
    expect(resolved.rpcUrl).toBe("https://env-mainnet.example/");
  });

  it("throws UNSUPPORTED_NETWORK for an unknown network name", () => {
    expect(() => resolveNetwork("devnet" as never)).toThrowError(QieForgeError);
    try {
      resolveNetwork("devnet" as never);
    } catch (err) {
      expect((err as QieForgeError).code).toBe("UNSUPPORTED_NETWORK");
    }
  });
});
