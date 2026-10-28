import { getPublicClient } from "@/lib/viemClient";
import { getFactoryAddress } from "@/lib/config";
import { FACTORY_ABI, PAIR_ABI } from "@/lib/contracts";

export interface PoolStats {
  pairAddress: `0x${string}`;
  token0: `0x${string}`;
  reserve0: string;
  reserve1: string;
  totalSupply: string;
}

/**
 * Pool-level AMM stats (reserves, LP total supply) for a given token pair —
 * global contract state, not per-user, same "no wallet required to see the
 * pool" posture `getVaultPoolStats` already established for `/vault`.
 * Resolves the pair address via the factory first since it's a CREATE2
 * address this app doesn't hardcode. Fails closed to `undefined` if the
 * factory isn't configured or the pair doesn't exist yet (e.g. only one
 * token in `NEXT_PUBLIC_QIE_FORGE_SWAP_TOKENS`, or liquidity never added).
 */
export async function getPoolStats(
  tokenA: `0x${string}`,
  tokenB: `0x${string}`,
): Promise<PoolStats | undefined> {
  const factoryAddress = getFactoryAddress();
  if (!factoryAddress) return undefined;

  try {
    const client = getPublicClient();
    const pairAddress = (await client.readContract({
      address: factoryAddress,
      abi: FACTORY_ABI,
      functionName: "getPair",
      args: [tokenA, tokenB],
    })) as `0x${string}`;
    if (!pairAddress || pairAddress === "0x0000000000000000000000000000000000000000") {
      return undefined;
    }

    const [reserves, token0, totalSupply] = await Promise.all([
      client.readContract({ address: pairAddress, abi: PAIR_ABI, functionName: "getReserves" }),
      client.readContract({ address: pairAddress, abi: PAIR_ABI, functionName: "token0" }),
      client.readContract({ address: pairAddress, abi: PAIR_ABI, functionName: "totalSupply" }),
    ]);
    const [reserve0, reserve1] = reserves as [bigint, bigint, number];

    return {
      pairAddress,
      token0: token0 as `0x${string}`,
      reserve0: reserve0.toString(),
      reserve1: reserve1.toString(),
      totalSupply: (totalSupply as bigint).toString(),
    };
  } catch {
    return undefined;
  }
}
