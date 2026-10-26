import { describe, expect, it, beforeEach, afterEach } from "vitest";
import { resolveQusdcConfig } from "../src/qusdc.js";
import { QieForgeError } from "../src/errors.js";

describe("resolveQusdcConfig (fail-closed asset config)", () => {
  const ORIGINAL_ENV = { ...process.env };

  beforeEach(() => {
    delete process.env.QIE_FORGE_QUSDC_ADDRESS;
    delete process.env.QIE_FORGE_QUSDC_DECIMALS;
  });

  afterEach(() => {
    process.env = { ...ORIGINAL_ENV };
  });

  it("throws ASSET_NOT_CONFIGURED when no address is configured anywhere", () => {
    expect(() => resolveQusdcConfig()).toThrowError(QieForgeError);
    try {
      resolveQusdcConfig();
    } catch (err) {
      expect((err as QieForgeError).code).toBe("ASSET_NOT_CONFIGURED");
    }
  });

  it("never invents a default address — explicit config is required", () => {
    const cfg = resolveQusdcConfig({ address: "0x1111111111111111111111111111111111111111" });
    expect(cfg.address).toBe("0x1111111111111111111111111111111111111111");
    expect(cfg.decimals).toBe(6); // documented default, only applied once an address is explicit
  });

  it("reads address from QIE_FORGE_QUSDC_ADDRESS env var", () => {
    process.env.QIE_FORGE_QUSDC_ADDRESS = "0x2222222222222222222222222222222222222222";
    process.env.QIE_FORGE_QUSDC_DECIMALS = "18";
    const cfg = resolveQusdcConfig();
    expect(cfg.address).toBe("0x2222222222222222222222222222222222222222");
    expect(cfg.decimals).toBe(18);
  });

  it("rejects a non-numeric decimals override", () => {
    process.env.QIE_FORGE_QUSDC_ADDRESS = "0x2222222222222222222222222222222222222222";
    process.env.QIE_FORGE_QUSDC_DECIMALS = "not-a-number";
    expect(() => resolveQusdcConfig()).toThrowError(QieForgeError);
  });
});
