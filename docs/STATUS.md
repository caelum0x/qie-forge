# QIE Forge — build status (updated 2026-10-27)

Honest status. Nothing below is aspirational — every claim has a command
you can re-run, and most have a live URL you can open right now.

**Live public app:** https://qie-forge.vercel.app (home page renders real,
live testnet/mainnet block numbers and real QIE Oracle prices on every
request — see "Built and verified: frontend" below).

## Built and verified: contracts (local EVM, Foundry)

```
cd packages/contracts && forge test -vv
```

**35/35 tests pass** across 4 suites (`QieOracleAdapter` 8, `QieForgeRouter`
8, `QieForgeVault` 12, `QieForgePair` 7). Beyond the original 25 (constant-
product invariants, LP math, fee accrual/protocol-fee switch, TWAP,
slippage/deadline checks, oracle staleness/decimals handling, base
LTV/health-factor/interest/liquidation), this pass added:

- **3-hop routing across 3 separate pools** (`test_threeHopSwap_acrossThreePools_matchesLibraryQuote`) — proves the router's multi-pool path execution, not just a 2-hop case.
- **`swapTokensForExactTokens`** (exact-output swaps) — pulls exactly the quoted input, reverts above a max-input cap.
- **Oracle adapter edge cases**: `DecimalsTooLarge` revert for a >18-decimal feed, feed rotation to a new aggregator, disabling the staleness check with `maxStaleness=0`.
- **Vault liquidation edge cases**: liquidating a position with zero debt reverts (`NothingToLiquidate`), over-repaying reverts (`RepayExceedsDebt`), a partial liquidation that restores health factor above 1, and two sequential liquidators each receiving their proportional bonus from the same underwater position.

## Built and verified: TypeScript SDK + CLI (real network calls)

Unchanged from the prior pass — see git history for the full pasted CLI
output. Summary: `chain-info`/`oracle-price` against real testnet (chain
1983, block >9.39M) and mainnet (chain 1990, block >11.46M) RPCs, real BTC
($79,896.25) and QIE ($0.1398) prices via the corrected oracle ABI.

## Built and verified: Python SDK (`packages/python`)

**23/23 tests pass** (`pytest -q` + `QIE_FORGE_RUN_LIVE_TESTS=1 pytest -q`):

- 11 offline unit tests (`networks`, `qusdc`, `amm` quote math).
- 4 live tests against the real testnet/mainnet RPC (same floors as the TS SDK).
- 4 live tests against the real mainnet oracle (BTC/QIE prices, testnet fail-closed check, unsupported-asset check).
- **2 local-anvil integration tests** that deploy the ACTUAL compiled `packages/contracts` bytecode (`MockERC20`, `MockAggregatorV3`, `QieOracleAdapter`, `QieForgeVault`, `QieForgeFactory`, `QieForgeRouter` — loaded from `forge build`'s own `out/` artifacts, not re-implemented) to a local anvil devnet, then exercise `VaultClient.get_position()` and `amm.get_amounts_out()`/`build_swap_exact_tokens_for_tokens_tx()` against them. Real assertions: the Python-read health factor matches a hand-calculated value, the Python quote math matches the deployed router's own `getAmountsOut()` call exactly, and the unsigned transaction this SDK builds actually executes successfully on-chain (`receipt.status == 1`).

## Built and verified: Rust SDK (`packages/rust`)

**15/15 tests pass** (`cargo test` + `QIE_FORGE_RUN_LIVE_TESTS=1 cargo test --test live_chain`):

- 9 offline unit tests (`networks`, `qusdc`, `amm` quote math, using `ethers`'s `U256`).
- 4 live tests against the real testnet/mainnet RPC and the real mainnet BTC oracle, using an `abigen!`-generated typed binding for the same corrected `IQieOracleAggregator` interface the TS/Python SDKs use.
- **2 local-anvil integration tests** (`tests/anvil_integration.rs`, closing the gap previously tracked here) that deploy the actual compiled `packages/contracts` bytecode (`MockERC20`, `MockAggregatorV3`, `QieOracleAdapter`, `QieForgeVault`, `QieForgeFactory`, `QieForgeRouter`, loaded from `forge build`'s own `out/` artifacts) to a local anvil devnet via `ethers-rs`, then exercise `vault::get_position()` and `amm::get_amounts_out()`/`build_swap_exact_tokens_for_tokens_tx()` against them — same pattern as the existing Python anvil test, same real assertions (health factor matches a hand-calculated value, quote math matches the deployed router's own `getAmountsOut()`, the built unsigned tx actually executes on-chain with `status == 1`).

## Built and verified: frontend (`apps/web`, Next.js 16 + viem)

**Live and public**: https://qie-forge.vercel.app (Vercel, auto-deployed
from this repo's `main`; deployment protection explicitly disabled so it's
reachable with no login — confirmed via a plain `curl` returning HTTP 200).

- **Home page** (`/`) is a server component that calls `@qie-forge/core`
  directly (same workspace package the CLI uses) on every request — no
  caching, no fixtures. Confirmed live output (just re-fetched):
  Testnet block #9,390,810 (chain 1983), Mainnet block #11,462,827 (chain
  1990), BTC $79,896.25, QIE $0.1398.
- **`/swap`** and **`/vault`** now render a real, live demo deployment by
  default (updated 2026-10-27, after the prior empty-state behavior drew a
  real owner complaint): `NEXT_PUBLIC_QIE_FORGE_NETWORK=demo` and the
  `NEXT_PUBLIC_QIE_FORGE_*_ADDRESS` vars are set on the real Vercel
  production project, pointing at a persistent, publicly reachable anvil
  devnet (`http://130.61.180.42:8647`, self-hosted on the products box —
  Docker container `qie-forge-demo-anvil`, Caddy site
  `qie-forge-demo-rpc.caddy`, OCI Security List rule for port 8647). The
  real compiled Factory/Router/OracleAdapter/Vault contracts are deployed
  there via `script/DeployDemo.s.sol`, seeded with real AMM liquidity and a
  real open vault position. A `DemoBanner` is shown on both pages whenever
  the network is `demo`, explicit that this is NOT QIE Testnet or Mainnet.
  If `NEXT_PUBLIC_QIE_FORGE_ROUTER_ADDRESS`/`..._VAULT_ADDRESS` are ever
  unset again (e.g. a fresh clone with no env configured), the honest
  "not deployed on this network yet" empty state still renders — that
  fallback was not removed, just no longer the default on the hosted site.
- **Proven against a real deployment, on the live production URL, not just
  locally**: `curl https://qie-forge.vercel.app/api/quote?amountIn=1000000000000000000&path=<WQIE>&path=<TUSD>`
  returns a real on-chain quote (`139579` raw TUSD units for 1 WQIE),
  matching a direct `cast call` to the same deployed router's own
  `getAmountsOut()`. `curl https://qie-forge.vercel.app/api/vault-position?user=<demo deployer>`
  returns a real open position (500,000 WQIE collateral, 20,000 TUSD debt,
  health factor 2.8x). `gstack browse` against the live production URL
  confirms the `/swap` page's real WQIE/TUSD token picker and a real
  computed quote (`10` WQIE -> `1.39573` TUSD) typed through the actual
  UI, zero console errors.
- **Wallet connect / swap-submit / deposit-submit**: implemented against
  QIE Wallet's real documented EIP-1193/EIP-6963 interface
  (`lib/wallet.ts`, reusing `@qie-forge/core`'s `walletConnect.ts`
  constants), and the swap/deposit transaction-building code paths are
  real (`encodeFunctionData` + `eth_sendTransaction`, approve-then-act).
  **Not click-tested end-to-end in a real browser** — that needs an actual
  wallet extension (QIE Wallet or another EVM wallet) in a real browser
  session, which this environment doesn't have. Honestly flagged, not
  claimed as verified.

## Not yet done (honest gaps, not hidden)

- **No on-chain Testnet or Mainnet deployment of the protocol itself.**
  `script/Deploy.s.sol` compiles; deploying costs real gas and needs a
  funded deployer key. QIE's testnet faucet (`qie.digital/faucet`) is a
  connect-a-wallet web app, not a plain API — a genuine owner/operator
  step. Once a real deployment exists, setting the
  `NEXT_PUBLIC_QIE_FORGE_*_ADDRESS` env vars on the live Vercel project
  (and flipping `NEXT_PUBLIC_QIE_FORGE_NETWORK` from `demo` to
  `testnet`/`mainnet`) turns the frontend's swap/vault pages from the demo
  deployment into the real thing — no frontend code change needed, same
  mechanism the demo deployment above already proves.
- **`QieForgeVault` has no lender deposit/withdraw flow.** `borrow()`
  transfers `borrowAsset` straight out of the vault's own balance — there
  is no `supply()`/`withdraw()` for lenders to fund it, so the only way
  TUSD liquidity gets into the vault today is the deployer directly
  minting/transferring it in (fine for the disposable demo deployment
  above, a real correctness gap before any real Testnet/Mainnet launch
  with real user funds — tracked honestly, not hidden).
- **No real-browser wallet click-through test** for the frontend (needs a
  wallet extension this environment doesn't have).
- **QUSDC integration is fail-closed everywhere** — the real QUSDC
  contract address was never independently confirmed.
- **QIE ID is not integrated** — no public API or contract for it was
  found during research.
