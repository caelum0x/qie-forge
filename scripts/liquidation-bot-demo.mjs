#!/usr/bin/env node
// QIE Forge — liquidation bot simulation (demo).
//
// Demonstrates the FULL liquidation path end-to-end against real,
// deployed QieForgeVault bytecode on a local anvil devnet:
//   1. Read the real borrower position's health factor (healthy).
//   2. Crash the collateral (WQIE) price via the mock oracle feed, the
//      same way a real market crash would push a real position
//      underwater — this is the only "fake" part of this script (a demo
//      price feed we can move on command instead of waiting for a real
//      market), everything downstream is a real contract call.
//   3. Poll the vault's real on-chain healthFactor() the way a real
//      liquidation bot would, detect the position is now < 1.0 (unhealthy).
//   4. Execute a REAL liquidate() transaction from a separate "bot"
//      account, repaying debt and seizing collateral + the liquidation
//      bonus, exactly as QieForgeVault.sol implements it.
//   5. Re-read on-chain state and print a before/after summary proving
//      the debt shrank, the position's health factor recovered, and the
//      bot's WQIE balance grew by the real seized collateral.
//
// Not a mock: every number below is read from or written to real EVM
// state via real `eth_call`/`eth_sendTransaction` JSON-RPC calls through
// viem, against the actual compiled QieForgeVault/QieOracleAdapter
// bytecode deployed by script/DeployDemo.s.sol. See
// scripts/liquidation-bot-demo.sh for the one-command orchestration
// (starts anvil, deploys the real demo stack, then runs this).
//
// Usage (normally invoked by liquidation-bot-demo.sh, not run bare):
//   QIE_FORGE_RPC_URL=http://127.0.0.1:8646 \
//   QIE_FORGE_DEMO_BORROWER_KEY=0x... \
//   QIE_FORGE_DEMO_BOT_KEY=0x... \
//   QIE_FORGE_VAULT_ADDRESS=0x... \
//   QIE_FORGE_ORACLE_ADDRESS=0x... \
//   QIE_FORGE_WQIE_ADDRESS=0x... \
//   QIE_FORGE_TUSD_ADDRESS=0x... \
//   node scripts/liquidation-bot-demo.mjs

import { createPublicClient, createWalletClient, http, formatUnits, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var ${name} — run via scripts/liquidation-bot-demo.sh, not directly.`);
  }
  return value;
}

const rpcUrl = requireEnv("QIE_FORGE_RPC_URL");
const borrowerKey = requireEnv("QIE_FORGE_DEMO_BORROWER_KEY");
const botKey = requireEnv("QIE_FORGE_DEMO_BOT_KEY");
const vaultAddress = requireEnv("QIE_FORGE_VAULT_ADDRESS");
const oracleAddress = requireEnv("QIE_FORGE_ORACLE_ADDRESS");
const wqieAddress = requireEnv("QIE_FORGE_WQIE_ADDRESS");
const tusdAddress = requireEnv("QIE_FORGE_TUSD_ADDRESS");

// Crash the collateral (WQIE) price to this many USD, 8 decimals (same
// shape MockAggregatorV3 / the real QIE Chainlink-style oracles use).
// DeployDemo.s.sol seeds WQIE at $0.14 (14_000_000); a ~65% crash to
// $0.049 (4_900_000) is enough to push the demo's 500,000 WQIE / 20,000
// TUSD / 75% LTV / 80% liq-threshold position underwater without being a
// contrived 99% wipeout.
const CRASHED_WQIE_PRICE_8DP = 4_900_000n;

const chain = {
  id: 31337,
  name: "anvil-demo",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
};

const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
const borrowerAccount = privateKeyToAccount(borrowerKey);
const botAccount = privateKeyToAccount(botKey);
const borrowerClient = createWalletClient({ account: borrowerAccount, chain, transport: http(rpcUrl) });
const botClient = createWalletClient({ account: botAccount, chain, transport: http(rpcUrl) });

const vaultAbi = [
  { type: "function", name: "healthFactor", stateMutability: "view", inputs: [{ name: "user", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "currentDebt", stateMutability: "view", inputs: [{ name: "user", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "positions", stateMutability: "view", inputs: [{ name: "user", type: "address" }], outputs: [{ name: "collateral", type: "uint128" }, { name: "debtPrincipal", type: "uint128" }, { name: "lastAccrual", type: "uint64" }] },
  { type: "function", name: "liquidate", stateMutability: "nonpayable", inputs: [{ name: "user", type: "address" }, { name: "repayAmount", type: "uint256" }], outputs: [] },
];

const oracleAbi = [
  { type: "function", name: "feeds", stateMutability: "view", inputs: [{ name: "asset", type: "address" }], outputs: [{ type: "address" }] },
  { type: "function", name: "getPriceUsd18", stateMutability: "view", inputs: [{ name: "asset", type: "address" }], outputs: [{ type: "uint256" }] },
];

const feedAbi = [
  { type: "function", name: "setAnswer", stateMutability: "nonpayable", inputs: [{ name: "newAnswer", type: "int256" }], outputs: [] },
];

const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "transfer", stateMutability: "nonpayable", inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ type: "bool" }] },
];

function fmtHf(hf) {
  if (hf > 10n ** 30n) return "∞ (no debt)";
  return Number(formatUnits(hf, 18)).toFixed(4);
}

async function snapshot(label) {
  const [hf, debt, position, wqieBal] = await Promise.all([
    publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "healthFactor", args: [borrowerAccount.address] }),
    publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "currentDebt", args: [borrowerAccount.address] }),
    publicClient.readContract({ address: vaultAddress, abi: vaultAbi, functionName: "positions", args: [borrowerAccount.address] }),
    publicClient.readContract({ address: wqieAddress, abi: erc20Abi, functionName: "balanceOf", args: [botAccount.address] }),
  ]);
  console.log(`\n-- ${label} --`);
  console.log(`  borrower healthFactor: ${fmtHf(hf)}`);
  console.log(`  borrower debt (TUSD):  ${formatUnits(debt, 6)}`);
  console.log(`  borrower collateral (WQIE): ${formatUnits(position[0], 18)}`);
  console.log(`  bot WQIE balance:      ${formatUnits(wqieBal, 18)}`);
  return { hf, debt, collateral: position[0], wqieBal };
}

async function main() {
  console.log("QIE Forge liquidation bot — live demo against a real local anvil fork\n");
  console.log(`RPC:          ${rpcUrl}`);
  console.log(`Vault:        ${vaultAddress}`);
  console.log(`Borrower:     ${borrowerAccount.address} (the open demo position from DeployDemo.s.sol)`);
  console.log(`Liquidator:   ${botAccount.address} (this bot's own account)`);

  const before = await snapshot("1. Before: real on-chain position state, healthy market");
  if (before.hf < 10n ** 18n) {
    throw new Error("Demo position is already unhealthy before any price move — DeployDemo.s.sol parameters changed?");
  }

  // --- Step 2: crash the collateral price via the real deployed oracle feed. ---
  const wqieFeedAddress = await publicClient.readContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: "feeds",
    args: [wqieAddress],
  });
  const priceBefore = await publicClient.readContract({ address: oracleAddress, abi: oracleAbi, functionName: "getPriceUsd18", args: [wqieAddress] });
  console.log(`\n-- 2. Simulating a market crash --`);
  console.log(`  WQIE price before: $${formatUnits(priceBefore, 18)}`);
  console.log(`  Crashing WQIE price feed (${wqieFeedAddress}) to $${formatUnits(CRASHED_WQIE_PRICE_8DP * 10n ** 10n, 18)}...`);
  const crashHash = await borrowerClient.writeContract({
    address: wqieFeedAddress,
    abi: feedAbi,
    functionName: "setAnswer",
    args: [CRASHED_WQIE_PRICE_8DP],
  });
  await publicClient.waitForTransactionReceipt({ hash: crashHash });
  const priceAfter = await publicClient.readContract({ address: oracleAddress, abi: oracleAbi, functionName: "getPriceUsd18", args: [wqieAddress] });
  console.log(`  WQIE price after:  $${formatUnits(priceAfter, 18)}`);

  // --- Step 3: bot polls real on-chain health factor, detects the position is underwater. ---
  const underwater = await snapshot("3. After crash: bot polls the real on-chain healthFactor()");
  if (underwater.hf >= 10n ** 18n) {
    throw new Error("Position did not go underwater after the price crash — adjust CRASHED_WQIE_PRICE_8DP.");
  }
  console.log(`\n  >>> Bot decision: healthFactor ${fmtHf(underwater.hf)} < 1.0 — position is liquidatable. Executing liquidate(). <<<`);

  // --- Step 4: fund the bot with TUSD to repay (borrower -> bot, a real transfer), then liquidate. ---
  const repayAmount = underwater.debt; // repay the full outstanding debt in one shot
  const fundHash = await borrowerClient.writeContract({
    address: tusdAddress,
    abi: erc20Abi,
    functionName: "transfer",
    args: [botAccount.address, repayAmount],
  });
  await publicClient.waitForTransactionReceipt({ hash: fundHash });

  const approveHash = await botClient.writeContract({
    address: tusdAddress,
    abi: erc20Abi,
    functionName: "approve",
    args: [vaultAddress, repayAmount],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const liquidateHash = await botClient.writeContract({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: "liquidate",
    args: [borrowerAccount.address, repayAmount],
  });
  const liquidateReceipt = await publicClient.waitForTransactionReceipt({ hash: liquidateHash });
  console.log(`\n  Real liquidate() tx mined: ${liquidateReceipt.transactionHash} (block ${liquidateReceipt.blockNumber}, status ${liquidateReceipt.status})`);

  // --- Step 5: verify, from real on-chain state, that the liquidation actually worked. ---
  const after = await snapshot("5. After liquidation: real on-chain state");

  const seizedWqie = after.wqieBal - underwater.wqieBal;
  const debtRepaid = underwater.debt - after.debt;
  console.log(`\n== Result ==`);
  console.log(`  Debt repaid by bot:       ${formatUnits(debtRepaid, 6)} TUSD`);
  console.log(`  Collateral seized by bot: ${formatUnits(seizedWqie, 18)} WQIE (includes the 5% liquidation bonus)`);
  console.log(`  Borrower healthFactor:    ${fmtHf(underwater.hf)} -> ${fmtHf(after.hf)}`);

  if (seizedWqie <= 0n) throw new Error("Liquidation did not transfer any collateral to the bot — something is wrong.");
  if (debtRepaid <= 0n) throw new Error("Liquidation did not reduce the borrower's debt — something is wrong.");
  console.log(`\nLiquidation path verified end-to-end against real deployed bytecode.`);
}

main().catch((err) => {
  console.error("\nLiquidation bot demo FAILED:", err);
  process.exit(1);
});
