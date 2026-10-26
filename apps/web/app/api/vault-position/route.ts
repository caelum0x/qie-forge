import { NextRequest, NextResponse } from "next/server";
import { isAddress } from "viem";
import { getPublicClient } from "@/lib/viemClient";
import { getVaultAddress } from "@/lib/config";
import { VAULT_ABI } from "@/lib/contracts";

export async function GET(req: NextRequest) {
  const vaultAddress = getVaultAddress();
  if (!vaultAddress) {
    return NextResponse.json({ error: "NOT_DEPLOYED", message: "No vault configured for this network yet." }, { status: 503 });
  }

  const user = new URL(req.url).searchParams.get("user");
  if (!user || !isAddress(user)) {
    return NextResponse.json({ error: "INVALID_REQUEST", message: "A valid `user` address is required" }, { status: 400 });
  }

  try {
    const client = getPublicClient();
    const [position, healthFactor, currentDebt] = await Promise.all([
      client.readContract({ address: vaultAddress, abi: VAULT_ABI, functionName: "positions", args: [user] }),
      client.readContract({ address: vaultAddress, abi: VAULT_ABI, functionName: "healthFactor", args: [user] }),
      client.readContract({ address: vaultAddress, abi: VAULT_ABI, functionName: "currentDebt", args: [user] }),
    ]);
    const [collateral, debtPrincipal, lastAccrual] = position as [bigint, bigint, bigint];

    return NextResponse.json({
      collateral: collateral.toString(),
      debtPrincipal: debtPrincipal.toString(),
      lastAccrual: lastAccrual.toString(),
      healthFactor: (healthFactor as bigint).toString(),
      currentDebt: (currentDebt as bigint).toString(),
    });
  } catch (err) {
    return NextResponse.json(
      { error: "READ_FAILED", message: err instanceof Error ? err.message : "Unknown error" },
      { status: 502 },
    );
  }
}
