#!/usr/bin/env node
import {
  ChainClient,
  ExplorerClient,
  OracleClient,
  resolveNetwork,
  type QieNetworkName,
  type QieOracleAsset,
} from "@qie-forge/core";
import { parseArgs, requireFlag } from "./args.js";

function asNetwork(value: string): QieNetworkName {
  if (value !== "testnet" && value !== "mainnet") {
    throw new Error(`--network must be "testnet" or "mainnet", got "${value}"`);
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

const COMMANDS: Record<string, (flags: Record<string, string>) => Promise<void>> = {
  "chain-info": cmdChainInfo,
  "oracle-price": cmdOraclePrice,
  balance: cmdBalance,
  "explorer-lookup": cmdExplorerLookup,
};

function printHelp(): void {
  console.log(`qie-forge <command> [--flags]

Commands:
  chain-info       --network <testnet|mainnet>
  oracle-price     --network <mainnet> --asset <BTC|ETH|XRP|SOL|QIE|XAUt|BNB>
  balance          --network <testnet|mainnet> --address <0x...>
  explorer-lookup  --network <testnet|mainnet> --address <0x...>
`);
}

async function main(): Promise<void> {
  const { command, flags } = parseArgs(process.argv.slice(2));
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
  await handler(flags);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exitCode = 1;
});
