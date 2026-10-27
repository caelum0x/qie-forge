import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Mock @qie-forge/core so these tests exercise the CLI's own dispatch, flag
// validation, and output-formatting logic without making any real network
// call — mirrors how packages/core/test/*.live.test.ts separates offline
// unit coverage from the QIE_FORGE_RUN_LIVE_TESTS=1 live suite.
const getSnapshotMock = vi.fn();
const getBalanceMock = vi.fn();
const getPriceMock = vi.fn();
const getAddressMock = vi.fn();
const addressUrlMock = vi.fn();

vi.mock("@qie-forge/core", () => {
  class ChainClient {
    config: { rpcUrl: string };
    constructor(public options: { network: string }) {
      this.config = { rpcUrl: `https://${options.network}.example/rpc` };
    }
    getSnapshot = getSnapshotMock;
    getBalance = getBalanceMock;
  }
  class OracleClient {
    constructor(
      public client: unknown,
      public options: { deployedNetworks: string[] },
    ) {}
    getPrice = getPriceMock;
  }
  class ExplorerClient {
    constructor(public network: unknown) {}
    getAddress = getAddressMock;
    addressUrl = addressUrlMock;
  }
  return {
    ChainClient,
    OracleClient,
    ExplorerClient,
    resolveNetwork: (name: string) => ({ name }),
  };
});

// Imported after the mock is registered (vi.mock is hoisted by vitest).
const { run, asNetwork, COMMANDS } = await import("../src/index.js");

describe("asNetwork", () => {
  it("accepts testnet and mainnet", () => {
    expect(asNetwork("testnet")).toBe("testnet");
    expect(asNetwork("mainnet")).toBe("mainnet");
  });

  it("rejects anything else with a descriptive error", () => {
    expect(() => asNetwork("devnet")).toThrowError(/--network must be "testnet" or "mainnet"/);
  });
});

describe("COMMANDS registry", () => {
  it("registers exactly the four documented commands", () => {
    expect(Object.keys(COMMANDS).sort()).toEqual(
      ["balance", "chain-info", "explorer-lookup", "oracle-price"].sort(),
    );
  });
});

describe("run()", () => {
  let logSpy: ReturnType<typeof vi.spyOn>;
  let errorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    process.exitCode = undefined;
    getSnapshotMock.mockReset();
    getBalanceMock.mockReset();
    getPriceMock.mockReset();
    getAddressMock.mockReset();
    addressUrlMock.mockReset();
  });

  afterEach(() => {
    logSpy.mockRestore();
    errorSpy.mockRestore();
  });

  it("prints help and exits cleanly when no command is given", async () => {
    await run([]);
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("qie-forge <command>"));
    expect(process.exitCode).toBeUndefined();
  });

  it("prints help for the explicit help command", async () => {
    await run(["help"]);
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("Commands:"));
  });

  it("sets a non-zero exit code and reports an unknown command", async () => {
    await run(["not-a-real-command"]);
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining('Unknown command "not-a-real-command"'));
    expect(process.exitCode).toBe(1);
  });

  it("chain-info defaults to testnet and prints a formatted snapshot", async () => {
    getSnapshotMock.mockResolvedValue({
      network: "testnet",
      chainId: 1983,
      blockNumber: 9_500_000n,
      blockHash: "0xdead",
      timestamp: 1_800_000_000n,
      gasPrice: 1_000_000_000n,
    });
    await run(["chain-info"]);
    expect(getSnapshotMock).toHaveBeenCalledTimes(1);
    const printed = JSON.parse((logSpy.mock.calls[0]?.[0] as string) ?? "{}");
    expect(printed).toMatchObject({
      network: "testnet",
      chainId: 1983,
      blockNumber: "9500000",
      blockHash: "0xdead",
      gasPriceWei: "1000000000",
      rpcUrl: "https://testnet.example/rpc",
    });
  });

  it("chain-info honors an explicit --network mainnet", async () => {
    getSnapshotMock.mockResolvedValue({
      network: "mainnet",
      chainId: 1990,
      blockNumber: 11_000_000n,
      blockHash: "0xbeef",
      timestamp: 1_800_000_000n,
      gasPrice: 2_000_000_000n,
    });
    await run(["chain-info", "--network", "mainnet"]);
    const printed = JSON.parse((logSpy.mock.calls[0]?.[0] as string) ?? "{}");
    expect(printed.network).toBe("mainnet");
    expect(printed.rpcUrl).toBe("https://mainnet.example/rpc");
  });

  it("chain-info rejects an invalid --network before calling the chain", async () => {
    await run(["chain-info", "--network", "bogus"]);
    expect(getSnapshotMock).not.toHaveBeenCalled();
    expect(errorSpy).toHaveBeenCalledWith(
      expect.stringContaining('--network must be "testnet" or "mainnet"'),
    );
    expect(process.exitCode).toBe(1);
  });

  it("balance requires --address and reports the missing flag", async () => {
    await run(["balance", "--network", "testnet"]);
    expect(getBalanceMock).not.toHaveBeenCalled();
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining("--address"));
    expect(process.exitCode).toBe(1);
  });

  it("balance prints wei and human-readable QIE for a valid address", async () => {
    getBalanceMock.mockResolvedValue(2_500_000_000_000_000_000n);
    await run(["balance", "--address", "0xabc123"]);
    expect(getBalanceMock).toHaveBeenCalledWith("0xabc123");
    const printed = JSON.parse((logSpy.mock.calls[0]?.[0] as string) ?? "{}");
    expect(printed).toEqual({
      network: "testnet",
      address: "0xabc123",
      balanceWei: "2500000000000000000",
      balanceQie: 2.5,
    });
  });

  it("oracle-price defaults to mainnet, uppercases the asset, and prints the decoded price", async () => {
    getPriceMock.mockResolvedValue({
      asset: "BTC",
      network: "mainnet",
      contractAddress: "0xoracle",
      description: "BTC / USD",
      answer: 6_000_000_000_000n,
      decimals: 8,
      roundId: 42n,
      updatedAt: 1_800_000_000n,
    });
    await run(["oracle-price", "--asset", "btc"]);
    expect(getPriceMock).toHaveBeenCalledWith("BTC");
    const printed = JSON.parse((logSpy.mock.calls[0]?.[0] as string) ?? "{}");
    expect(printed.price).toBe(60_000);
    expect(printed.roundId).toBe("42");
  });

  it("explorer-lookup merges the address URL into the printed result", async () => {
    getAddressMock.mockResolvedValue({ address: "0xabc", nonce: 3, isContract: false });
    addressUrlMock.mockReturnValue("https://explorer.example/address/0xabc");
    await run(["explorer-lookup", "--address", "0xabc"]);
    const printed = JSON.parse((logSpy.mock.calls[0]?.[0] as string) ?? "{}");
    expect(printed).toEqual({
      address: "0xabc",
      nonce: 3,
      isContract: false,
      url: "https://explorer.example/address/0xabc",
    });
  });

  it("catches a handler error, prints the message, and sets a non-zero exit code", async () => {
    getSnapshotMock.mockRejectedValue(new Error("RPC unreachable"));
    await run(["chain-info"]);
    expect(errorSpy).toHaveBeenCalledWith("RPC unreachable");
    expect(process.exitCode).toBe(1);
  });
});
