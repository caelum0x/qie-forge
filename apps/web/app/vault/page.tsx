import { getVaultAddress, getNetworkName } from "@/lib/config";
import { VaultCard } from "@/components/VaultCard";
import { AlertIcon } from "@/components/icons";
import { DemoBanner } from "@/components/DemoBanner";

export default function VaultPage() {
  const vaultAddress = getVaultAddress();
  const collateralAddress = process.env.NEXT_PUBLIC_QIE_FORGE_VAULT_COLLATERAL_ADDRESS as
    | `0x${string}`
    | undefined;
  const collateralDecimals = Number(process.env.NEXT_PUBLIC_QIE_FORGE_VAULT_COLLATERAL_DECIMALS ?? 18);

  return (
    <div className="mx-auto max-w-5xl px-6 py-16">
      <h1 className="text-2xl font-semibold text-foreground mb-6">Lending Vault</h1>
      {getNetworkName() === "demo" && <DemoBanner />}

      {vaultAddress && collateralAddress ? (
        <VaultCard
          vaultAddress={vaultAddress}
          collateralAddress={collateralAddress}
          collateralDecimals={collateralDecimals}
        />
      ) : (
        <div className="card p-6 max-w-md flex items-start gap-3">
          <AlertIcon className="w-5 h-5 text-muted mt-0.5" />
          <p className="text-sm text-muted">
            No vault configured for this network yet (
            <code className="text-xs">NEXT_PUBLIC_QIE_FORGE_VAULT_ADDRESS</code>). The vault contract
            itself — deposit, borrow, health factor, liquidation — is built and tested; see{" "}
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
