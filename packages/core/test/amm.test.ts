import { describe, expect, it } from "vitest";
import { getAmountIn, getAmountOut, quote, buildSwapExactTokensForTokensTx, AmmQuoteError } from "../src/amm.js";

const WAD = 10n ** 18n;
const wad = (n: bigint) => n * WAD;

describe("AMM quote math (mirrors QieForgeLibrary.sol / amm.py / amm.rs)", () => {
  it("getAmountOut matches the hand-calculated 30bps-fee formula", () => {
    const amountIn = wad(100n);
    const reserveIn = wad(10_000n);
    const reserveOut = wad(10_000n);
    const amountInWithFee = amountIn * 9970n;
    const expected = (amountInWithFee * reserveOut) / (reserveIn * 10_000n + amountInWithFee);
    expect(getAmountOut(amountIn, reserveIn, reserveOut)).toBe(expected);
    expect(expected).toBeLessThan(amountIn);
  });

  it("getAmountOut and getAmountIn round-trip within rounding error", () => {
    const reserveIn = wad(50_000n);
    const reserveOut = wad(20_000n);
    const amountIn = wad(1_000n);
    const amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
    const recoveredIn = getAmountIn(amountOut, reserveIn, reserveOut);
    const diff = recoveredIn > amountIn ? recoveredIn - amountIn : amountIn - recoveredIn;
    expect(diff).toBeLessThanOrEqual(2n);
  });

  it("quote is proportional with no fee applied", () => {
    expect(quote(100n, 1000n, 4000n)).toBe(400n);
  });

  it("rejects non-positive inputs", () => {
    expect(() => getAmountOut(0n, 1000n, 1000n)).toThrowError(AmmQuoteError);
    expect(() => getAmountIn(1000n, 1000n, 500n)).toThrowError(AmmQuoteError);
    expect(() => quote(0n, 1000n, 1000n)).toThrowError(AmmQuoteError);
  });

  it("buildSwapExactTokensForTokensTx encodes a real swapExactTokensForTokens call", () => {
    const router = "0x0000000000000000000000000000000000000001";
    const tokenA = "0x0000000000000000000000000000000000000002";
    const tokenB = "0x0000000000000000000000000000000000000003";
    const to = "0x0000000000000000000000000000000000000004";
    const { to: callTarget, data } = buildSwapExactTokensForTokensTx(
      router,
      wad(1n),
      0n,
      [tokenA, tokenB],
      to,
      9_999_999_999n,
    );
    expect(callTarget.toLowerCase()).toBe(router.toLowerCase());
    expect(data.startsWith("0x38ed1739")).toBe(true); // swapExactTokensForTokens selector
  });

  it("rejects an invalid address before encoding anything", () => {
    expect(() =>
      buildSwapExactTokensForTokensTx("not-an-address", 1n, 0n, ["0x1", "0x2"], "0x3", 1n),
    ).toThrow(/valid EVM address/);
  });
});
