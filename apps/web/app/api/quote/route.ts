import { NextRequest, NextResponse } from "next/server";
import { getPublicClient } from "@/lib/viemClient";
import { getRouterAddress } from "@/lib/config";
import { ROUTER_ABI } from "@/lib/contracts";

/** Real on-chain quote via the deployed QieForgeRouter's own
 * getAmountsOut — never computed off-chain/estimated here, so the number
 * shown always matches what the actual swap would do. */
export async function GET(req: NextRequest) {
  const routerAddress = getRouterAddress();
  if (!routerAddress) {
    return NextResponse.json({ error: "NOT_DEPLOYED", message: "No router configured for this network yet." }, { status: 503 });
  }

  const { searchParams } = new URL(req.url);
  const amountIn = searchParams.get("amountIn");
  const path = searchParams.getAll("path");

  if (!amountIn || path.length < 2) {
    return NextResponse.json({ error: "INVALID_REQUEST", message: "amountIn and at least 2 `path` entries are required" }, { status: 400 });
  }

  try {
    const client = getPublicClient();
    const amounts = await client.readContract({
      address: routerAddress,
      abi: ROUTER_ABI,
      functionName: "getAmountsOut",
      args: [BigInt(amountIn), path as `0x${string}`[]],
    });
    return NextResponse.json({ amounts: (amounts as bigint[]).map(String) });
  } catch (err) {
    return NextResponse.json(
      { error: "QUOTE_FAILED", message: err instanceof Error ? err.message : "Unknown error" },
      { status: 502 },
    );
  }
}
