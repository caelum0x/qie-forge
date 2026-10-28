# QIE Forge — build status (updated 2026-10-28)

Honest status. Nothing below is aspirational — every claim has a command
you can re-run, and most have a live URL you can open right now.

**Live public app:** https://qie-forge.vercel.app (home page renders real,
live testnet/mainnet block numbers and real QIE Oracle prices on every
request — see "Built and verified: frontend" below).

## 2026-10-28: lender vault UI shipped, two real bugs found and fixed on the live demo

Real hardening pass (not a new feature from scratch): used the live site as a
real user would, found the `/vault` page only ever exposed
`depositCollateral()` — never `borrow()`, `repay()`, `withdrawCollateral()`,
or the lender-side `deposit()`/`withdraw()` that have existed in the
contract and SDKs since commit `f55e3c6` — and while wiring those up, found
two real, currently-live defects:

1. **Wrong chain ID on wallet connect.** `SwapCard`/`VaultCard`'s own
   "Connect Wallet" buttons hardcoded `connect(1983)` (QIE Testnet), so on
   the live demo site (`NEXT_PUBLIC_QIE_FORGE_NETWORK=demo`, chain 31337)
   a real wallet user clicking either button would be told to switch to
   the wrong chain — every subsequent `eth_sendTransaction` would target a
   network with nothing deployed. The header's own `WalletConnectButton`
   already derived `chainId` correctly from `getNetworkConfig()`; the two
   duplicated in-card buttons just never reused that. Fixed: both cards
   now call `connect(getNetworkConfig().chainId)`.
2. **The live demo oracle went stale and `borrow()`/`healthFactor()`
   started reverting for everyone, including the documented demo
   position.** `QieOracleAdapter`'s staleness check (`maxStalenessSeconds`)
   was set to 3600s against a `MockAggregatorV3` whose `updatedAt` is only
   ever set once, at deploy time — so ~1 hour after any deploy,
   `StalePrice` starts reverting forever. Confirmed live:
   `cast call healthFactor(deployer)` reverted with `StalePrice` before the
   fix. Fixed two ways: (a) called the deployed oracle's `setMaxStaleness`
   (owner-only, deployer key held) to 100 years on the live instance —
   confirmed `healthFactor(deployer)` returns `2.8e18` again immediately
   after; (b) changed `DeployDemo.s.sol`'s oracle constructor to the same
   ~10-year window so a future redeploy doesn't reintroduce this.

**A third, more serious issue surfaced while building the lender UI and
testing it against the real deployed contract, not just reading the
source**: `QieForgeVault.deposit()`'s "first depositor mints 1:1" rule
ignored any `totalAssets()` that already existed before `totalLenderShares`
was ever nonzero — exactly the state `DeployDemo.s.sol`'s own seeding
pattern creates (500,000 TUSD minted straight into the vault, never
through `deposit()`). Reproduced for real against the live (pre-fix)
contract: depositing 1,000 TUSD as the first-ever lender minted 1,000
shares worth **501,000 TUSD** (100% of `totalAssets()`, including the
pre-funded 500,000 + the deployer's 20,000 outstanding debt) — a real,
practically-zero-cost drain of operator-seeded launch liquidity, the exact
textbook ERC4626 "donation/inflation" attack, with no mitigation (unlike
`QieForgePair`'s `MINIMUM_LIQUIDITY` burn-to-`0xdEaD`, which this contract
had no equivalent of). **Fixed in
`packages/contracts/src/vault/QieForgeVault.sol`**: added
`MINIMUM_LENDER_SHARES = 1000`, permanently locked (attributed to nobody)
on the first deposit into a vault whose `totalAssets()` is already
nonzero, sized so the depositor's own shares are worth exactly what they
put in and the locked floor absorbs the pre-existing value — a genuinely
pristine vault (`totalAssets() == 0`) still mints 1:1, unchanged. Two new
Foundry tests added:
`test_deposit_firstDepositor_cannotDrainPreFundedLiquidity` (direct
reproduction + fix assertion) and
`test_deposit_freshVault_firstDepositorStillMints1to1` (regression guard
for the unaffected case). **`forge test`: 43/43 pass** (was 41/41).
Re-verified live against a freshly redeployed demo stack (new addresses,
same seed amounts, same documented 500,000/20,000/2.8x numbers): the exact
same attack now round-trips exactly 1,000 TUSD in, 1,000 TUSD out — no
windfall. **No real funds were ever at risk** — this was found and fixed
entirely before any QIE Testnet/Mainnet deployment; the live demo chain's
tokens have zero real value, and the vulnerable (pre-fix) bytecode's live
instance was abandoned, not patched in place (immutable bytecode), by
redeploying fresh with the fixed source.

**Shipped**: `components/VaultCard.tsx` (deposit/withdraw collateral,
borrow, repay) and a new `components/LendCard.tsx` (supply/withdraw
liquidity as a lender, with live pool stats: your supplied value, your
shares, idle liquidity, total outstanding debt) are both live on
`/vault`. New ABI entries in `lib/contracts.ts`
(`withdrawCollateral`/`repay`/`deposit`/`withdraw`/`lenderShares`/
`totalLenderShares`/`totalAssets`/`totalDebtPrincipal`/`borrowAsset`), a
shared `lib/erc20Actions.ts` (`ensureAllowance`/`sendContractCall`) used by
both the swap and vault/lend flows instead of duplicating the
approve-then-send pattern. Verified the exact encoding every handler uses
against the live redeployed contract with `cast send`/`cast call` using
real anvil test accounts: `depositCollateral` → `borrow` → `repay` →
`withdrawCollateral` round-trips cleanly, and lender `deposit` → `withdraw`
round-trips cleanly post-fix. `next build`/`next lint` clean, zero type
errors. Not click-tested with a real wallet extension (same honest gap as
the swap/deposit flow already had — this environment has no browser
wallet).

**Infra**: the self-hosted demo RPC (`qie-forge-demo-rpc.caddy`, public on
`:8647`) had silently dropped out of `/etc/caddy/sites-enabled/` a second
time (first was 2026-10-27) because it was never added to this box's
managed `caddy/sites/` directory or `CADDY_SITES` list, so every
`install.sh caddy` run regenerated the enabled set without it. Fixed for
real this time (not another hand-copy into `/etc/caddy/`): added the site
file to `infra-box/caddy/sites/qie-forge-demo-rpc.caddy` and
`qie-forge-demo-rpc` to `CADDY_SITES` on the box, verified a second
`install.sh caddy` run keeps it enabled.

## Built and verified: contracts (local EVM, Foundry)

```
cd packages/contracts && forge test -vv
```

**43/43 tests pass** across 4 suites (`QieOracleAdapter` 8, `QieForgeRouter`
8, `QieForgeVault` 20, `QieForgePair` 7) — see "2026-10-28" section above
for the two newest (the real donation/inflation-attack regression tests).
Beyond the original 25 (constant-
product invariants, LP math, fee accrual/protocol-fee switch, TWAP,
slippage/deadline checks, oracle staleness/decimals handling, base
LTV/health-factor/interest/liquidation), this pass added:

- **3-hop routing across 3 separate pools** (`test_threeHopSwap_acrossThreePools_matchesLibraryQuote`) — proves the router's multi-pool path execution, not just a 2-hop case.
- **`swapTokensForExactTokens`** (exact-output swaps) — pulls exactly the quoted input, reverts above a max-input cap.
- **Oracle adapter edge cases**: `DecimalsTooLarge` revert for a >18-decimal feed, feed rotation to a new aggregator, disabling the staleness check with `maxStaleness=0`.
- **Vault liquidation edge cases**: liquidating a position with zero debt reverts (`NothingToLiquidate`), over-repaying reverts (`RepayExceedsDebt`), a partial liquidation that restores health factor above 1, and two sequential liquidators each receiving their proportional bonus from the same underwater position.
- **Lender deposit/withdraw share accounting** (`test_deposit_mintsSharesAtExchangeRate`, `test_deposit_lenderSharesAppreciateFromBorrowerInterest`, `test_withdraw_redeemsSharesForUnderlying`, `test_withdraw_revertsWhenLiquidityIsLentOut`, `test_withdraw_belowLtvThreshold_reverts`, `test_withdraw_revertsWhenSharesExceedBalance`, `test_liquidation_cannotSeizeMoreThanAvailableCollateral`, `test_liquidation_minimalRepayStillZeroesDebt_whenCollateralExhausted`) — `QieForgeVault.deposit()`/`withdraw()` exist and are covered; a stale claim that this flow was missing (repeated across a couple of commit messages without re-reading the file) has been corrected below and in this file's own history.

## Built and verified: TypeScript SDK + CLI (real network calls)

`chain-info`/`oracle-price` against real testnet (chain 1983, block
>9.39M) and mainnet (chain 1990, block >11.46M) RPCs, real BTC
($79,896.25) and QIE ($0.1398) prices via the corrected oracle ABI.
**24/24 CLI unit tests pass** (`npm run test -w packages/cli`, vitest):
10 tests for `args.ts` (`parseArgs`/`requireFlag` edge cases) and 14 for
`index.ts`'s command dispatch (`chain-info`/`oracle-price`/`balance`/
`explorer-lookup` output formatting, network validation, missing-flag and
unknown-command error paths, handler-error-to-exitCode propagation),
run against a mocked `@qie-forge/core` so they're fast and offline —
closing the "zero test files" gap `packages/cli/test/` previously had.

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
- **No real-browser wallet click-through test** for the frontend (needs a
  wallet extension this environment doesn't have).
- **QUSDC integration is fail-closed everywhere** — the real QUSDC
  contract address was never independently confirmed.
- **QIE ID is not integrated** — no public API or contract for it was
  found during research.
