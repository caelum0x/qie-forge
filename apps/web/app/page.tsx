import { ChainClient, OracleClient, type QieOracleAsset } from "@qie-forge/core";
import { AlertIcon } from "@/components/icons";

export const dynamic = "force-dynamic";

async function loadNetworkStats() {
  const [testnet, mainnet] = await Promise.allSettled([
    new ChainClient({ network: "testnet" }).getSnapshot(),
    new ChainClient({ network: "mainnet" }).getSnapshot(),
  ]);

  let prices: { asset: QieOracleAsset; price: number; description: string }[] = [];
  if (mainnet.status === "fulfilled") {
    const oracle = new OracleClient(new ChainClient({ network: "mainnet" }), { deployedNetworks: ["mainnet"] });
    const results = await Promise.allSettled(
      (["BTC", "QIE"] as QieOracleAsset[]).map((asset) => oracle.getPrice(asset)),
    );
    prices = results
      .filter((r): r is PromiseFulfilledResult<Awaited<ReturnType<typeof oracle.getPrice>>> => r.status === "fulfilled")
      .map((r) => ({
        asset: r.value.asset,
        price: Number(r.value.answer) / 10 ** r.value.decimals,
        description: r.value.description,
      }));
  }

  return { testnet, mainnet, prices };
}

export default async function HomePage() {
  const { testnet, mainnet, prices } = await loadNetworkStats();

  return (
    <div className="mx-auto max-w-5xl px-6 py-16">
      <section className="max-w-2xl">
        <h1 className="text-3xl font-semibold tracking-tight text-foreground">
          A real AMM and lending vault for QIE.
        </h1>
        <p className="mt-3 text-muted">
          Clean-room constant-product swaps and over-collateralized borrowing, built from first
          principles for the QIE blockchain. Not a fork — every formula is derived in the source.
        </p>
      </section>

      <section className="mt-10 grid grid-cols-1 sm:grid-cols-2 gap-4">
        <NetworkCard
          label="Testnet (1983)"
          result={testnet}
        />
        <NetworkCard
          label="Mainnet (1990)"
          result={mainnet}
        />
      </section>

      {prices.length > 0 && (
        <section className="mt-6 grid grid-cols-1 sm:grid-cols-2 gap-4">
          {prices.map((p) => (
            <div key={p.asset} className="card p-5">
              <p className="text-xs text-muted">{p.description} · live from QIE Oracle</p>
              <p className="mt-1 text-2xl font-semibold text-foreground">
                {p.asset === "QIE" ? `$${p.price.toFixed(4)}` : `$${p.price.toLocaleString(undefined, { maximumFractionDigits: 2 })}`}
              </p>
            </div>
          ))}
        </section>
      )}

      <section className="mt-10 card p-5 flex items-start gap-3">
        <AlertIcon className="w-5 h-5 text-muted mt-0.5" />
        <p className="text-sm text-muted">
          The protocol contracts are fully built and tested (35/35 Foundry tests) but not yet
          deployed on-chain — that needs a funded deployer wallet, a real owner/operator step (see{" "}
          <a className="underline hover:text-foreground" href="https://github.com/caelum0x/qie-forge/blob/main/docs/STATUS.md">
            docs/STATUS.md
          </a>
          ). The network stats above are real, live data from QIE&apos;s actual testnet and mainnet RPCs and oracle
          contracts — this page makes no simulated calls.
        </p>
      </section>
    </div>
  );
}

function NetworkCard({
  label,
  result,
}: {
  label: string;
  result: PromiseSettledResult<{ blockNumber: bigint; chainId: number; gasPrice: bigint }>;
}) {
  return (
    <div className="card p-5">
      <p className="text-xs text-muted">{label}</p>
      {result.status === "fulfilled" ? (
        <>
          <p className="mt-1 text-2xl font-semibold text-foreground">
            #{result.value.blockNumber.toString()}
          </p>
          <p className="mt-1 text-xs text-muted">chain id {result.value.chainId} · live block</p>
        </>
      ) : (
        <p className="mt-1 text-sm text-danger">Unreachable right now</p>
      )}
    </div>
  );
}
