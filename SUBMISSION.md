# QIE Forge — QIE Mainnet Hackathon 3.0 submission

**Track:** DeFi & Financial Infrastructure
**Live demo:** https://qie-forge.vercel.app
**Repo:** https://github.com/caelum0x/qie-forge (MIT license)

This doc is the 5-minute version for judges. For the full, continuously-updated
honest status (exact commands, exact live output), see
[`docs/STATUS.md`](docs/STATUS.md). For the research/finding writeups behind
each claim below, see the [README](README.md)'s "Real findings" section and
[`docs/HACKATHON.md`](docs/HACKATHON.md).

## The problem

QIE is a live EVM-compatible L1 (mainnet chain ID 1990, testnet 1983, a
working Blockscout explorer, a documented wallet and oracle) — but it has
**no public DEX and no public lending protocol**. `QIE Dex` is listed as an
ecosystem component on QIE's own site with no discoverable open contracts or
source. Every other serious L1/L2 ecosystem's first load-bearing DeFi
primitive is a constant-product AMM plus an over-collateralized money
market; QIE doesn't have one yet. QIE Forge is that primitive, built clean-room
for this hackathon.

## What's built

- **`packages/contracts`** (Foundry, Solidity 0.8.26, MIT) — a clean-room
  constant-product AMM (`QieForgeFactory` / `QieForgePair` / `QieForgeRouter`)
  and an isolated over-collateralized lending vault (`QieForgeVault`), plus an
  oracle adapter (`QieOracleAdapter`) that talks to QIE's *real* deployed price
  feeds. No existing DEX/lending protocol's source was read or copied — every
  formula is derived from first principles in each contract's NatSpec.
  **62/62 Foundry tests pass** (`cd packages/contracts && forge test -vv`),
  covering AMM invariants, LP share math, fee accrual, TWAP accumulation,
  multi-hop routing (including 3-pool paths and exact-output swaps), oracle
  staleness/decimals/rotation edge cases, vault health-factor/liquidation
  edge cases (including a specific liquidation-exploit regression test, see
  "Security findings" below), a real protocol **reserve factor** —
  `QieForgeVault.reserveFactorBps` carves out a configurable share of every
  borrower's accrued interest (10% in the demo deploy) into withdrawable
  `treasury` revenue instead of passing 100% of it to lenders — and a real
  **severity-scaled liquidation incentive curve**: `liquidationBonusBpsFor`
  pays a liquidator more (up to `liquidationBonusMaxBps`, 20% in the demo
  deploy) the further underwater a position is, instead of the flat
  `liquidationBonusBps` rate every real money market (Compound/Aave) pays
  regardless of severity — closing the real incentive gap where a liquidator
  had no extra reason to race to save the protocol from the positions most
  likely to become unrecoverable bad debt. Also a real **aggregate borrow
  cap** (`QieForgeVault.borrowCap`, 100,000 TUSD in the demo deploy):
  per-position LTV alone says nothing about whether a vault *as a whole*
  has grown larger than this market can safely absorb, the same gap
  Compound's per-market `borrowCaps` / Aave's per-reserve borrow cap both
  close — proven live against the real deployed demo bytecode with
  `./scripts/borrow-cap-demo.sh`.
- **Three SDKs, one protocol**: `@qie-forge/core` (TypeScript/viem),
  `packages/python` (web3.py), `packages/rust` (ethers-rs) — each
  independently implements the same chain/oracle/qusdc/AMM read/quote logic,
  not thin wrappers around each other. **33/33 JS tests, 23/23 Python tests,
  15/15 Rust tests pass offline**, plus real anvil-deployment integration
  tests (Python and Rust) that deploy the actual compiled contract bytecode
  and prove the SDK's computed quote/health-factor matches the contract's own
  on-chain values exactly.
- **`packages/cli`** (`@qie-forge/cli`) — a small CLI on top of the TS SDK:
  `chain-info`, `oracle-price`, `balance`, `explorer-lookup`. 24/24 tests.
- **`apps/web`** — a live, public Next.js 16 frontend
  (https://qie-forge.vercel.app), no login wall. Home page calls the SDK
  directly on every request (real block numbers, real oracle prices, no
  caching/fixtures). `/swap` and `/vault` render a real, live demo deployment
  by default (see "Live demo walkthrough" below) with wallet-connect
  scaffolding against QIE Wallet's real documented EIP-1193/EIP-6963
  interface.

## Live demo walkthrough (verified working right now, see below for exact timestamps)

1. Open https://qie-forge.vercel.app — the home page shows the real current
   QIE Testnet and Mainnet block numbers and the real BTC/USDT and QIE/USDT
   prices pulled live from QIE's actual oracle contracts.
2. Open `/swap` — a "demo" banner marks this as a disposable demo network
   (self-hosted anvil devnet, chain ID 31337), not QIE Testnet/Mainnet (see
   "Honest current gaps" below for why). Type an amount into the WQIE/TUSD
   swap form; the quote comes back from a real deployed `QieForgeRouter`
   contract via `getAmountsOut()`, not a mock.
3. Open `/vault` — shows a real open borrow position (500,000 WQIE
   collateral, 20,000 TUSD debt, health factor ~2.8x) read live from the
   deployed `QieForgeVault` contract.
4. CLI equivalent of step 1: `node packages/cli/dist/index.js chain-info
   --network testnet` / `--network mainnet`, and `oracle-price --network
   mainnet --asset BTC`.

See [`docs/DEMO-SCRIPT.md`](docs/DEMO-SCRIPT.md) for a full numbered,
judge-ready walkthrough script (exact URLs, exact CLI commands, exact
expected output) suitable for recording the hackathon's required demo video.

## Real findings from building this (not claims — every one has a re-runnable command)

1. **QIE's own Oracle developer docs describe a function that doesn't exist.**
   `docs.qie.digital/qie-oracle` documents `getPrice(string) view returns
   (uint256)`. Calling that exact signature against the real deployed BTC
   oracle (`0x9E596d809a20A272c788726f592c0d1629755440`, Mainnet) **reverts**.
   The actual deployed bytecode is a Chainlink `AggregatorV3Interface` clone
   — confirmed by raw `eth_call`: `decimals()` → `8`, `description()` →
   `"BTC / USDT"`, `latestRoundData()` → a real non-zero round. `QieOracleAdapter`
   and all three SDKs implement the corrected interface and fail closed
   (`ORACLE_NOT_DEPLOYED`) rather than trusting the docs or guessing.
2. **The documented testnet RPC is dead.** `https://rpc1testnet.qie.digital/`
   (the one still listed in QIE's own "Builder Quickstart" on the hackathon
   site today) returns `ECONNREFUSED`. The real, live testnet RPC is QIE's
   own Blockscout explorer's JSON-RPC proxy: `https://testnet.qie.digital/api/eth-rpc`
   — confirmed via a real `eth_chainId` call (`0x7bf` = 1983).
3. **The oracle is Mainnet-only.** The same 7 published feed addresses
   (BTC/ETH/XRP/SOL/QIE/XAUt/BNB) have real bytecode on Mainnet but
   `eth_getCode` returns `"0x"` on Testnet at the same addresses.
4. **No general-purpose, multi-language QIE developer SDK existed before
   this** — only single-protocol JS SDKs (`qie-lend-sdk`, `qusdc-sdk`), no
   CLI, no Python/Rust clients.

## Security findings and fixes (on our own contracts, before any deployment — no funds at risk)

An external security researcher flagged a real issue in `QieForgeVault`.
Independently re-verified by reading the contract directly, not taken on the
vendor's word:

1. No lender deposit/withdraw path existed at the time — liquidity could only
   enter via a direct token transfer, with no way for a lender to ever
   reclaim principal.
2. `liquidate()` could leave permanent bad debt: a rational liquidator could
   choose the smallest `repayAmount` that still exhausted the available
   collateral, leaving `debtPrincipal > 0` against zero collateral forever.

**Both fixed before any on-chain deployment** (commit `f55e3c6`): added
ERC4626-style lender share accounting (`deposit()`/`withdraw()`, priced
against `totalAssets()`), and capped `repayAmount` to what the seized
collateral actually covers, writing off the uncovered remainder
(`BadDebtWrittenOff`) instead of leaving it stuck. A dedicated regression
test, `test_liquidation_minimalRepayStillZeroesDebt_whenCollateralExhausted`,
reproduces the exact exploit and proves debt now always reaches zero
alongside collateral. A follow-up adversarial pass over the AMM/Router
(reentrancy, TWAP manipulation paths, LP rounding, access control, slippage/
deadline handling) found no further exploitable issue — documented honestly
in `docs/STATUS.md`'s history, not hidden.

3. **Self-found, same session (2026-10-29), while adding the liquidation-
   bonus curve**: the forward seize calculation in `liquidate()` was
   updated to use the new severity-scaled `bonusBps`, but the *inverse*
   calculation in the same function's "collateral is the binding
   constraint" branch (`coveredValueUsd`, used to cap `repayAmount` and
   compute `badDebt` when a position's collateral runs out mid-liquidation)
   was left reading the old flat `liquidationBonusBps` — the two bonus
   rates would have silently diverged for any deeply-underwater,
   collateral-exhausted liquidation (exactly the case most likely to hit
   that branch), corrupting the bad-debt write-off amount. Caught by
   re-reading the diff before writing tests, not by a failing test —
   fixed in the same commit, before any test (or deployment) ever
   exercised the broken path.

## How to run this locally

```bash
# Contracts
cd packages/contracts && forge install && forge build && forge test -vv

# TypeScript SDK + CLI
npm install && npm run build
node packages/cli/dist/index.js chain-info --network testnet
node packages/cli/dist/index.js oracle-price --network mainnet --asset BTC

# Python SDK
cd packages/python && python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]" && pytest -q

# Rust SDK
cd packages/rust && cargo test

# Frontend
cd apps/web && npm install && npm run dev
```

## Judging criteria mapping (using QIE's own published weights)

| Criterion (weight) | How QIE Forge addresses it |
|---|---|
| Innovation (30%) | Clean-room AMM + lending vault combo, built around an independently-discovered correction to QIE's own oracle docs — most entrants would copy the broken `getPrice(string)` sample and silently fail. |
| Technical Quality (25%) | 62/62 Foundry tests, 3 independently-implemented SDKs with real anvil-deployment integration tests (not mocks), five real bugs (liquidation bad-debt, a wrong wallet chain-ID on connect, a lender-share donation/inflation attack, a lender-share pricing-staleness gap, and a bonus-rate inconsistency in `liquidate()`'s own collateral-exhausted branch introduced and caught within this same pass before shipping) found and fixed pre-deployment, each with a reproducing regression test or live re-verification. |
| User Experience (15%) | Live public frontend, no login wall, real swap quotes and vault positions rendered end-to-end through the actual UI, not screenshots; `/vault`'s pool-level stats (including protocol reserves) render with zero wallet connection required. |
| Mainnet Integration (15%) | **Honest gap — see below.** Oracle/explorer/RPC integration is against real QIE Mainnet contracts and endpoints today; the protocol's own contracts are not yet deployed to QIE Mainnet. |
| Business Potential (15%) | A working DEX + money market is the single most load-bearing DeFi primitive a new L1 needs, and the vault's `reserveFactorBps` already gives the protocol a real on-chain revenue line (a configurable cut of every borrower's interest, withdrawable by `treasury`) rather than just passing 100% of it through to lenders — swap/LP/borrow activity plus that reserve capture are exactly the recurring, measurable usage *and* monetizable usage the hackathon's own traction milestones reward. The severity-scaled liquidation-bonus curve (`liquidationBonusMaxBps`) is a real risk-management maturity signal too: it directly reduces expected bad-debt losses (the single biggest tail risk to that same revenue line) by making sure the positions most likely to go unrecovered get liquidated fastest. |

## Honest current gaps (not hidden — this is what's still open)

QIE's own FAQ states submissions must include **mainnet deployment** and that
**"Testnet-only projects are not eligible. Judges verify contracts,
transactions, deployment, and frontend connectivity on QIE Mainnet."**
QIE Forge's protocol contracts (Factory/Router/Vault) are **not yet deployed
to QIE Testnet or Mainnet** — this is the single most important remaining
gap, bigger than packaging. It is blocked on a funded QIE Mainnet deployer
wallet: QIE's testnet faucet (`qie.digital/faucet`) is a connect-a-wallet web
app, not a plain API, and mainnet deployment needs real funded QIE, both
genuine owner/operator steps this environment cannot do on its own. Everything
else (contract code, test suite, SDKs, frontend, oracle integration) is ready
to point at a real deployment the moment one exists — `script/Deploy.s.sol`
compiles today, and the frontend's `NEXT_PUBLIC_QIE_FORGE_*` env vars are a
one-line flip from `demo` to `testnet`/`mainnet`, proven by the live demo
deployment already running against this exact code path.

Also still open, honestly: no real-browser wallet click-through test (needs
an actual wallet extension); QUSDC integration stays fail-closed (its real
contract address was never independently confirmed publicly); QIE ID is not
integrated (no public API/contract found for it).

## License

MIT — see [`LICENSE`](LICENSE). Contracts carry `SPDX-License-Identifier: MIT`
headers individually.
