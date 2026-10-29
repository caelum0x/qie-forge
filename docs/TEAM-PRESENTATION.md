# QIE Forge — team presentation

QIE Mainnet Hackathon 3.0 · Track: DeFi & Financial Infrastructure

## What we built

QIE Forge is a clean-room AMM/DEX plus an over-collateralized lending vault
for the QIE blockchain, with three independent SDKs (TypeScript, Python,
Rust), a CLI, and a live public frontend. It is a new financial protocol
built from first principles for QIE — not a fork, not a port, not a thin
wrapper around someone else's contracts.

- **`QieForgeFactory` / `QieForgePair` / `QieForgeRouter`** — constant-product
  (x·y=k) AMM: 30bps fee compounding into reserves, minimum-liquidity burn to
  block the classic empty-pool attack, price-cumulative TWAP accumulators,
  multi-hop routing with slippage/deadline protection.
- **`QieForgeVault`** — over-collateralized lending: deposit, borrow up to an
  LTV cap, real-time health-factor computation blending QIE's real oracle
  with the pool's own TWAP, permissionless liquidation with a bonus,
  ERC4626-style lender share accounting.
- **`QieOracleAdapter`** — the first (and only, as far as we found) correct
  implementation of QIE's real oracle interface — see "Technical highlight 1"
  below.
- **Three SDKs + CLI** — the same chain/oracle/AMM/vault logic implemented
  independently in viem, web3.py, and ethers-rs, each with its own real test
  suite including anvil-deployment integration tests against the actual
  compiled contract bytecode.
- **Live frontend** — https://qie-forge.vercel.app, public, no login,
  real on-chain data on every request.

## Technical highlight 1 — we found and fixed a bug in QIE's own documentation

QIE's public Oracle docs (`docs.qie.digital/qie-oracle`) specify
`function getPrice(string) view returns (uint256)`. We called that exact
signature against the real deployed BTC price feed on QIE Mainnet. It
reverts — the function doesn't exist on the deployed contract. By decoding
the actual bytecode's function selectors, we found the real deployed
contracts are Chainlink `AggregatorV3Interface` clones (`decimals()`,
`description()`, `latestRoundData()`), confirmed with live `eth_call`s, not
guesses. `QieOracleAdapter` and all three SDKs implement the corrected
interface and fail closed rather than trusting the docs. Most hackathon
entrants integrating QIE's oracle for the first time would copy the
documented (wrong) signature and either silently fail or fabricate a result —
we found the real contract behavior and built against it.

We also found and fixed: the documented testnet RPC endpoint
(`rpc1testnet.qie.digital`) is dead (`ECONNREFUSED`) — still listed on the
hackathon site's own "Builder Quickstart" today — and the real working
endpoint is QIE's Blockscout explorer's own JSON-RPC proxy; and that the
oracle contracts only have bytecode deployed on Mainnet, not Testnet, at the
same addresses.

## Technical highlight 2 — a real security bug found and fixed pre-deployment

An external security reviewer flagged a real issue in `QieForgeVault`. We
independently re-verified it by reading the contract source directly, not
taking the report on faith:

1. No lender deposit/withdraw function existed — liquidity could only enter
   via a direct token transfer, with no path for a lender to ever reclaim
   principal.
2. `liquidate()` could be gamed to leave permanent bad debt: a liquidator
   could choose the smallest repay amount that still exhausted the available
   collateral, leaving debt principal stranded against zero collateral,
   forever, with nobody incentivized to ever call `liquidate()` again on that
   position.

Both were fixed (commit `f55e3c6`) before any on-chain deployment — no funds
were ever at risk. We added ERC4626-style lender share accounting priced
against `totalAssets()`, and capped the liquidator's effective repay amount
to what the seized collateral actually covers, writing off the shortfall via
a `BadDebtWrittenOff` event instead of leaving a dangling balance. A
dedicated regression test,
`test_liquidation_minimalRepayStillZeroesDebt_whenCollateralExhausted`,
reproduces the exact exploit path and proves debt and collateral now always
reach zero together. We then ran the same adversarial scrutiny over the
AMM/Router (reentrancy, TWAP manipulation, LP rounding, access control,
slippage/deadline enforcement) and found no further exploitable issue —
documented honestly either way, not just when we found something.

## Technical highlight 3 — verified, not just tested

- **43/43 Foundry tests** across the full contract suite.
- **33/33 TypeScript, 23/23 Python, 15/15 Rust tests**, each SDK built
  independently (not a thin wrapper around the others).
- **Real anvil-deployment integration tests** in both the Python and Rust
  SDKs: they deploy the actual compiled contract bytecode (not a mock) to a
  local devnet and prove the SDK's computed health factor and swap quote
  match the deployed contract's own values exactly, including a built
  unsigned transaction that actually executes on-chain.
- **A real, persistent, publicly reachable demo deployment** — a self-hosted
  anvil devnet with the real compiled contracts deployed, seeded with real
  liquidity and an open vault position — so the live frontend shows real
  on-chain reads end-to-end today, while QIE Testnet/Mainnet deployment
  waits on a funded deployer key.

## Judging criteria mapping (QIE's published weights)

| Criterion | Weight | QIE Forge |
|---|---|---|
| Innovation | 30% | Clean-room AMM + lending vault, built around an independently-discovered oracle-docs bug most entrants would copy blindly. |
| Technical Quality | 25% | 64/64 contract tests, 3 independent SDKs with real anvil-integration tests, five real security bugs (liquidation bad-debt, lender-share donation/inflation attack, lender-share pricing staleness, a bonus-rate inconsistency in the liquidation-curve work caught in the same pass, and a bad-debt-write-off-vs-realized-protocol-reserves insolvency/DoS gap that could permanently freeze every lender's funds) found and fixed pre-deployment, each with a reproducing regression test. |
| User Experience | 15% | Live public frontend, real swap/vault flows working end-to-end, no login wall. |
| Mainnet Integration | 15% | Oracle/RPC/explorer integration is real and QIE-Mainnet-verified today; the protocol's own contract deployment to QIE Mainnet is the one open gap (see below). |
| Business Potential | 15% | A DEX + money market is the load-bearing DeFi primitive QIE doesn't have yet, and the vault now has a real on-chain revenue line (`reserveFactorBps`, a configurable cut of borrower interest withdrawable by `treasury`) plus a severity-scaled liquidation incentive curve (`liquidationBonusMaxBps`) that reduces expected bad-debt losses against that revenue — on top of the recurring swap/LP/borrow activity the hackathon's traction milestones reward. |

## What's honestly still open

- **QIE Testnet/Mainnet deployment of the protocol contracts.** QIE's FAQ
  states plainly: "Testnet-only projects are not eligible. Judges verify
  contracts, transactions, deployment, and frontend connectivity on QIE
  Mainnet." This is blocked on a funded QIE Mainnet deployer wallet — a real
  owner/operator step (QIE's testnet faucet is a connect-a-wallet flow, not a
  plain API; mainnet needs real funded QIE). Everything else is built and
  ready to point at it the moment it exists.
- No real-browser wallet click-through test (needs an actual wallet
  extension).
- QUSDC integration stays fail-closed — its real contract address was never
  independently confirmed publicly.
- QIE ID is not integrated — no public API or contract was found for it.

## The team

Built solo for QIE Mainnet Hackathon 3.0, with AI-assisted development (QIE's
own FAQ: "Yes, AI-assisted development is encouraged. Teams must fully
understand and maintain their code and be able to explain architecture to
judges.") — every claim in this document and in `docs/STATUS.md` is backed
by a command you can re-run yourself, which is the standard we held
ourselves to throughout.
