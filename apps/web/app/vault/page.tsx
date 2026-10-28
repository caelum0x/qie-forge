import {
  getVaultAddress,
  getNetworkName,
  getVaultCollateralSymbol,
  getVaultBorrowAddress,
  getVaultBorrowDecimals,
  getVaultBorrowSymbol,
} from "@/lib/config";
import { getVaultPoolStats } from "@/lib/vaultStats";
import { VaultCard } from "@/components/VaultCard";
import { LendCard } from "@/components/LendCard";
import { VaultPoolStatsBar } from "@/components/VaultPoolStatsBar";
import { AlertIcon } from "@/components/icons";
import { DemoBanner } from "@/components/DemoBanner";

export const dynamic = "force-dynamic";

export default async function VaultPage() {
  const vaultAddress = getVaultAddress();
  const poolStats = await getVaultPoolStats();
  const collateralAddress = process.env.NEXT_PUBLIC_QIE_FORGE_VAULT_COLLATERAL_ADDRESS as
    | `0x${string}`
    | undefined;
  const collateralDecimals = Number(process.env.NEXT_PUBLIC_QIE_FORGE_VAULT_COLLATERAL_DECIMALS ?? 18);
  const collateralSymbol = getVaultCollateralSymbol();
  const borrowAddress = getVaultBorrowAddress();
  const borrowDecimals = getVaultBorrowDecimals();
  const borrowSymbol = getVaultBorrowSymbol();

  return (
    <div className="mx-auto max-w-5xl px-6 py-16">
      <h1 className="text-2xl font-semibold text-foreground mb-6">Lending Vault</h1>
      {getNetworkName() === "demo" && <DemoBanner />}

      {poolStats && borrowAddress && (
        <VaultPoolStatsBar stats={poolStats} borrowDecimals={borrowDecimals} borrowSymbol={borrowSymbol} />
      )}

      {vaultAddress && collateralAddress ? (
        <div className="flex flex-wrap gap-6">
          <VaultCard
            vaultAddress={vaultAddress}
            collateralAddress={collateralAddress}
            collateralDecimals={collateralDecimals}
            collateralSymbol={collateralSymbol}
            borrowAddress={borrowAddress}
            borrowDecimals={borrowDecimals}
            borrowSymbol={borrowSymbol}
          />
          {borrowAddress && (
            <LendCard
              vaultAddress={vaultAddress}
              borrowAddress={borrowAddress}
              borrowDecimals={borrowDecimals}
              borrowSymbol={borrowSymbol}
            />
          )}
        </div>
      ) : (
        <div className="card p-6 max-w-md flex items-start gap-3">
          <AlertIcon className="w-5 h-5 text-muted mt-0.5" />
          <p className="text-sm text-muted">
            No vault configured for this network yet (
            <code className="text-xs">NEXT_PUBLIC_QIE_FORGE_VAULT_ADDRESS</code>). The vault contract
            itself — deposit, borrow, health factor, liquidation, lender shares — is built and tested; see{" "}
            <a className="underline hover:text-foreground" href="https://github.com/caelum0x/qie-forge/blob/main/packages/contracts/src/vault/QieForgeVault.sol">
              QieForgeVault.sol
            </a>
            .
          </p>
        </div>
      )}
    </div>
  );
}
