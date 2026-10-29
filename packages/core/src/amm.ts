import { encodeFunctionData, isAddress, type Address, type Hex } from "viem";
import type { ChainClient } from "./chain.js";
import { QieForgeError } from "./errors.js";

/**
 * Pure constant-product routing math + swap-transaction building — mirrors
 * packages/contracts/src/libraries/QieForgeLibrary.sol and
 * packages/contracts/src/QieForgeRouter.sol exactly (same 30bps fee, same
 * formulas), and packages/python/qie_forge/amm.py /
 * packages/rust/src/amm.rs field-for-field.
 *
 * This did not exist in @qie-forge/core before — the Python and Rust SDKs
 * both shipped a full AMM quoting module on 2026-10-27, but the TypeScript
 * SDK (the one `apps/web` and `@qie-forge/cli` actually depend on) never
 * got the equivalent, so a TS caller had no way to quote a swap or build a
 * router transaction except by re-deriving the frontend's bespoke
 * `apps/web/lib` code. Closed here for real SDK parity across all three
 * languages.
 */

export const FEE_BPS = 30n;
export const BPS_DENOMINATOR = 10_000n;

export const FACTORY_ABI = [
  {
    type: "function",
    name: "getPair",
    stateMutability: "view",
    inputs: [
      { name: "tokenA", type: "address" },
      { name: "tokenB", type: "address" },
    ],
    outputs: [{ name: "pair", type: "address" }],
  },
] as const;

export const PAIR_ABI = [
  {
    type: "function",
    name: "getReserves",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "reserve0", type: "uint112" },
      { name: "reserve1", type: "uint112" },
      { name: "blockTimestampLast", type: "uint32" },
    ],
  },
  {
    type: "function",
    name: "token0",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

export const ROUTER_ABI = [
  {
    type: "function",
    name: "swapExactTokensForTokens",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "path", type: "address[]" },
      { name: "to", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "amounts", type: "uint256[]" }],
  },
  {
    type: "function",
    name: "getAmountsOut",
    stateMutability: "view",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "path", type: "address[]" },
    ],
    outputs: [{ name: "", type: "uint256[]" }],
  },
] as const;

export class AmmQuoteError extends QieForgeError {
  constructor(message: string, details?: Record<string, unknown>) {
    super("INVALID_RESPONSE", message, details);
  }
}

function assertAddress(address: string): Address {
  if (!isAddress(address)) {
    throw new QieForgeError("INVALID_ADDRESS", `"${address}" is not a valid EVM address`, { address });
  }
  return address as Address;
}

/** Same formula as `QieForgeLibrary.getAmountOut` — 30bps fee taken from the input. */
export function getAmountOut(amountIn: bigint, reserveIn: bigint, reserveOut: bigint): bigint {
  if (amountIn <= 0n) throw new AmmQuoteError("amountIn must be positive");
  if (reserveIn <= 0n || reserveOut <= 0n) throw new AmmQuoteError("reserves must be positive");
  const amountInWithFee = amountIn * (BPS_DENOMINATOR - FEE_BPS);
  const numerator = amountInWithFee * reserveOut;
  const denominator = reserveIn * BPS_DENOMINATOR + amountInWithFee;
  return numerator / denominator;
}

/** Same formula as `QieForgeLibrary.getAmountIn` — the exact-output inverse of getAmountOut. */
export function getAmountIn(amountOut: bigint, reserveIn: bigint, reserveOut: bigint): bigint {
  if (amountOut <= 0n) throw new AmmQuoteError("amountOut must be positive");
  if (reserveIn <= 0n || reserveOut <= amountOut) {
    throw new AmmQuoteError("insufficient liquidity for requested amountOut");
  }
  const numerator = reserveIn * amountOut * BPS_DENOMINATOR;
  const denominator = (reserveOut - amountOut) * (BPS_DENOMINATOR - FEE_BPS);
  return numerator / denominator + 1n;
}

/** Same formula as `QieForgeLibrary.quote` — proportional amount, no fee. */
export function quote(amountA: bigint, reserveA: bigint, reserveB: bigint): bigint {
  if (amountA <= 0n) throw new AmmQuoteError("amountA must be positive");
  if (reserveA <= 0n || reserveB <= 0n) throw new AmmQuoteError("reserves must be positive");
  return (amountA * reserveB) / reserveA;
}

/** Reads the real on-chain reserves for a tokenA/tokenB pair through the factory. */
export async function getReserves(
  chain: ChainClient,
  factoryAddress: string,
  tokenA: string,
  tokenB: string,
): Promise<[bigint, bigint]> {
  const factory = assertAddress(factoryAddress);
  const a = assertAddress(tokenA);
  const b = assertAddress(tokenB);

  const pair = await chain.readContract<Address>({
    address: factory,
    abi: FACTORY_ABI,
    functionName: "getPair",
    args: [a, b],
  });
  if (pair === "0x0000000000000000000000000000000000000000") {
    throw new AmmQuoteError(`No pair deployed for ${tokenA}/${tokenB} on ${factoryAddress}`, {
      factoryAddress,
      tokenA,
      tokenB,
    });
  }

  const [reserve0, reserve1] = await chain.readContract<readonly [bigint, bigint, number]>({
    address: pair,
    abi: PAIR_ABI,
    functionName: "getReserves",
    args: [],
  });
  const token0 = await chain.readContract<Address>({
    address: pair,
    abi: PAIR_ABI,
    functionName: "token0",
    args: [],
  });

  return a.toLowerCase() === token0.toLowerCase() ? [reserve0, reserve1] : [reserve1, reserve0];
}

/**
 * Walks a multi-hop `path`, reading real on-chain reserves at each hop and
 * applying the same pure quote math as `getAmountOut` — gives a TS caller
 * the identical quote a real `QieForgeRouter.getAmountsOut()` call would
 * return, without needing a round-trip through the router contract itself.
 */
export async function getAmountsOut(
  chain: ChainClient,
  factoryAddress: string,
  amountIn: bigint,
  path: string[],
): Promise<bigint[]> {
  if (path.length < 2) throw new AmmQuoteError("path must have at least 2 tokens");
  const amounts: bigint[] = [amountIn];
  for (let i = 0; i < path.length - 1; i++) {
    const [reserveIn, reserveOut] = await getReserves(chain, factoryAddress, path[i], path[i + 1]);
    amounts.push(getAmountOut(amounts[amounts.length - 1], reserveIn, reserveOut));
  }
  return amounts;
}

/**
 * Builds an UNSIGNED `swapExactTokensForTokens` call against a real
 * deployed router — `{ to, data }`, the same minimal shape a real wallet
 * needs to sign and broadcast. Never signs or broadcasts itself, same
 * posture as `build_swap_exact_tokens_for_tokens_tx` in the Python/Rust
 * SDKs — this SDK never holds or uses a private key.
 */
export function buildSwapExactTokensForTokensTx(
  routerAddress: string,
  amountIn: bigint,
  amountOutMin: bigint,
  path: string[],
  to: string,
  deadline: bigint,
): { to: Address; data: Hex } {
  const router = assertAddress(routerAddress);
  const recipient = assertAddress(to);
  const checkedPath = path.map(assertAddress);
  const data = encodeFunctionData({
    abi: ROUTER_ABI,
    functionName: "swapExactTokensForTokens",
    args: [amountIn, amountOutMin, checkedPath, recipient, deadline],
  });
  return { to: router, data };
}
