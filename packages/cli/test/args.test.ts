import { describe, expect, it } from "vitest";
import { parseArgs, requireFlag } from "../src/args.js";

describe("parseArgs", () => {
  it("extracts the command and leaves flags empty when none are given", () => {
    expect(parseArgs(["chain-info"])).toEqual({ command: "chain-info", flags: {} });
  });

  it("returns an undefined command for an empty argv", () => {
    expect(parseArgs([])).toEqual({ command: undefined, flags: {} });
  });

  it("parses a `--flag value` pair", () => {
    const parsed = parseArgs(["balance", "--network", "testnet", "--address", "0xabc"]);
    expect(parsed).toEqual({
      command: "balance",
      flags: { network: "testnet", address: "0xabc" },
    });
  });

  it("treats a trailing flag with no value as the boolean string \"true\"", () => {
    const parsed = parseArgs(["chain-info", "--verbose"]);
    expect(parsed.flags).toEqual({ verbose: "true" });
  });

  it("treats a flag immediately followed by another flag as boolean \"true\", not consuming the next flag's name as its value", () => {
    const parsed = parseArgs(["oracle-price", "--verbose", "--asset", "BTC"]);
    expect(parsed.flags).toEqual({ verbose: "true", asset: "BTC" });
  });

  it("ignores bare positional tokens that are not prefixed with --", () => {
    const parsed = parseArgs(["chain-info", "extra-positional", "--network", "mainnet"]);
    expect(parsed.flags).toEqual({ network: "mainnet" });
  });

  it("last occurrence of a repeated flag wins", () => {
    const parsed = parseArgs(["chain-info", "--network", "testnet", "--network", "mainnet"]);
    expect(parsed.flags.network).toBe("mainnet");
  });
});

describe("requireFlag", () => {
  it("returns the value when the flag is present", () => {
    expect(requireFlag({ network: "testnet" }, "network")).toBe("testnet");
  });

  it("throws a descriptive error naming the missing flag", () => {
    expect(() => requireFlag({}, "address")).toThrowError(/--address/);
  });

  it("throws on an empty-string value (falsy, same as missing)", () => {
    expect(() => requireFlag({ address: "" }, "address")).toThrowError(/--address/);
  });
});
