import { NextRequest, NextResponse } from "next/server";
import { isAddress } from "viem";
import { getPublicClient } from "@/lib/viemClient";
import { getFactoryAddress } from "@/lib/config";
import { ERC20_ABI } from "@/lib/contracts";
import { getPoolStats } from "@/lib/poolStats";

/** Real on-chain LP position for a connected wallet: pool-level stats
 * (reserves/total supply, same ones `/pool` shows with no wallet
 * connected) plus this user's own LP token balance, so LiquidityCard can
 * show "your share" and compute a safe `removeLiquidity` amount. */
export async function GET(req: NextRequest) {
  const factoryAddress = getFactoryAddress();
  if (!factoryAddress) {
    return NextResponse.json(
      { error: "NOT_DEPLOYED", message: "No factory configured for this network yet." },
      { status: 503 },
    );
  }

  const { searchParams } = new URL(req.url);
  const tokenA = searchParams.get("tokenA");
  const tokenB = searchParams.get("tokenB");
  const user = searchParams.get("user");

  if (!tokenA || !isAddress(tokenA) || !tokenB || !isAddress(tokenB)) {
    return NextResponse.json(
      { error: "INVALID_REQUEST", message: "Valid `tokenA` and `tokenB` addresses are required" },
      { status: 400 },
    );
  }
  if (!user || !isAddress(user)) {
    return NextResponse.json({ error: "INVALID_REQUEST", message: "A valid `user` address is required" }, { status: 400 });
  }

  try {
    const stats = await getPoolStats(tokenA as `0x${string}`, tokenB as `0x${string}`);
    if (!stats) {
      return NextResponse.json(
        { error: "NO_POOL", message: "No pool exists for this pair yet — be the first to add liquidity." },
        { status: 404 },
      );
    }

    const client = getPublicClient();
    const lpBalance = await client.readContract({
      address: stats.pairAddress,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [user],
    });

    return NextResponse.json({ ...stats, lpBalance: (lpBalance as bigint).toString() });
  } catch (err) {
    return NextResponse.json(
      { error: "READ_FAILED", message: err instanceof Error ? err.message : "Unknown error" },
      { status: 502 },
    );
  }
}
