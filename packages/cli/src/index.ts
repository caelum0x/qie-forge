#!/usr/bin/env node
import {
  ChainClient,
  ExplorerClient,
  OracleClient,
  VaultClient,
  getAmountsOut,
  isLiquidatable,
  resolveNetwork,
  type QieNetworkName,
  type QieOracleAsset,
} from "@qie-forge/core";
import { parseArgs, requireFlag } from "./args.js";

/** Exported so test/index.test.ts can verify validation without spawning the CLI process. */
export function asNetwork(value: string): QieNetworkName {
  if (value !== "testnet" && value !== "mainnet" && value !== "demo") {
    throw new Error(`--network must be "testnet", "mainnet", or "demo", got "${value}"`);
  }
  return value;
}

async function cmdChainInfo(flags: Record<string, string>): Promise<void> {
  const network = asNetwork(flags.network ?? "testnet");
  const client = new ChainClient({ network });
  const snapshot = await client.getSnapshot();
  console.log(
    JSON.stringify(
      {
        network: snapshot.network,
        chainId: snapshot.chainId,
        blockNumber: snapshot.blockNumber.toString(),
        blockHash: snapshot.blockHash,
        timestamp: new Date(Number(snapshot.timestamp) * 1000).toISOString(),
        gasPriceWei: snapshot.gasPrice.toString(),
        rpcUrl: client.config.rpcUrl,
      },
      null,
      2,
    ),
  );
}

async function cmdOraclePrice(flags: Record<string, string>): Promise<void> {
  const network = asNetwork(flags.network ?? "mainnet");
  const asset = requireFlag(flags, "asset").toUpperCase() as QieOracleAsset;
  const client = new ChainClient({ network });
  const oracle = new OracleClient(client, { deployedNetworks: ["mainnet"] });
  const result = await oracle.getPrice(asset);
  const human = Number(result.answer) / 10 ** result.decimals;
  console.log(
    JSON.stringify(
      {
        asset: result.asset,
        network: result.network,
        contract: result.contractAddress,
        description: result.description,
        price: human,
        rawAnswer: result.answer.toString(),
        decimals: result.decimals,
        roundId: result.roundId.toString(),
        updatedAt: new Date(Number(result.updatedAt) * 1000).toISOString(),
      },
      null,
      2,
    ),
  );
}

async function cmdBalance(flags: Record<string, string>): Promise<void> {
  const network = asNetwork(flags.network ?? "testnet");
  const address = requireFlag(flags, "address");
  const client = new ChainClient({ network });
  const balanceWei = await client.getBalance(address);
  console.log(
    JSON.stringify(
      { network, address, balanceWei: balanceWei.toString(), balanceQie: Number(balanceWei) / 1e18 },
      null,
      2,
    ),
  );
}

async function cmdExplorerLookup(flags: Record<string, string>): Promise<void> {
  const network = asNetwork(flags.network ?? "testnet");
  const address = requireFlag(flags, "address");
  const explorer = new ExplorerClient(resolveNetwork(network));
  const info = await explorer.getAddress(address);
  console.log(JSON.stringify({ ...info, url: explorer.addressUrl(address) }, null, 2));
}

/**
 * These two commands close the same gap `packages/core/src/vault.ts` and
 * `amm.ts` do — Python's/Rust's SDKs each shipped a vault-position lookup
 * and an AMM quote on 2026-10-27, but neither the TypeScript SDK nor this
 * CLI (which is built directly on @qie-forge/core) ever got the
 * equivalent. `--network demo` is required for these today because the
 * real protocol has no Testnet/Mainnet deployment yet (see docs/STATUS.md
 * — blocked on a funded deployer wallet); it points at the same
 * self-hosted anvil devnet backing the live /vault and /swap frontend.
 */
async function cmdVaultPosition(flags: Record<string, string>): Promise<void> {
  const network = asNetwork(flags.network ?? "testnet");
  const vault = requireFlag(flags, "vault");
  const user = requireFlag(flags, "user");
  const client = new ChainClient({ network });
  const vaultClient = new VaultClient(client, vault);
  const [position, ltvBps, liquidationThresholdBps] = await Promise.all([
    vaultClient.getPosition(user),
    vaultClient.getLtvBps(),
    vaultClient.getLiquidationThresholdBps(),
  ]);
  console.log(
    JSON.stringify(
      {
        network,
        vault,
        user,
        collateral: position.collateral.toString(),
        debtPrincipal: position.debtPrincipal.toString(),
        lastAccrual: position.lastAccrual.toString(),
        healthFactor: position.healthFactor.toString(),
        currentDebt: position.currentDebt.toString(),
        ltvBps: ltvBps.toString(),
        liquidationThresholdBps: liquidationThresholdBps.toString(),
        isLiquidatable: isLiquidatable(position),
      },
      null,
      2,
    ),
  );
}

async function cmdAmmQuote(flags: Record<string, string>): Promise<void> {
  const network = asNetwork(flags.network ?? "testnet");
  const factory = requireFlag(flags, "factory");
  const amountIn = BigInt(requireFlag(flags, "amount-in"));
  const path = requireFlag(flags, "path").split(",").map((token) => token.trim());
  const client = new ChainClient({ network });
  const amounts = await getAmountsOut(client, factory, amountIn, path);
  console.log(
    JSON.stringify(
      {
        network,
        factory,
        path,
        amountIn: amountIn.toString(),
        amounts: amounts.map((a) => a.toString()),
        amountOut: amounts[amounts.length - 1].toString(),
      },
      null,
      2,
    ),
  );
}

export const COMMANDS: Record<string, (flags: Record<string, string>) => Promise<void>> = {
  "chain-info": cmdChainInfo,
  "oracle-price": cmdOraclePrice,
  balance: cmdBalance,
  "explorer-lookup": cmdExplorerLookup,
  "vault-position": cmdVaultPosition,
  "amm-quote": cmdAmmQuote,
};

export function printHelp(): void {
  console.log(`qie-forge <command> [--flags]

Commands:
  chain-info       --network <testnet|mainnet|demo>
  oracle-price     --network <mainnet> --asset <BTC|ETH|XRP|SOL|QIE|XAUt|BNB>
  balance          --network <testnet|mainnet|demo> --address <0x...>
  explorer-lookup  --network <testnet|mainnet> --address <0x...>
  vault-position   --network <testnet|mainnet|demo> --vault <0x...> --user <0x...>
  amm-quote        --network <testnet|mainnet|demo> --factory <0x...> --amount-in <wei> --path <0x...,0x...>
`);
}

/**
 * Exported so test/index.test.ts can exercise command dispatch directly.
 * Catches handler errors itself (rather than relying on main()'s .catch) so
 * run() has one consistent exit-code contract whether it's invoked as the
 * real CLI binary or directly from a test.
 */
export async function run(argv: string[]): Promise<void> {
  const { command, flags } = parseArgs(argv);
  if (!command || command === "help" || command === "--help") {
    printHelp();
    return;
  }
  const handler = COMMANDS[command];
  if (!handler) {
    console.error(`Unknown command "${command}". Run "qie-forge help".`);
    process.exitCode = 1;
    return;
  }
  try {
    await handler(flags);
  } catch (err) {
    console.error(err instanceof Error ? err.message : err);
    process.exitCode = 1;
  }
}

// Only auto-run when executed as the CLI binary, not when imported by tests.
if (process.env.VITEST === undefined) {
  run(process.argv.slice(2));
}
