# QIE Forge

**Live app: https://qie-forge.vercel.app**

A from-scratch DeFi protocol for the [QIE blockchain](https://qie.digital) — an
AMM/DEX (`QieForgeFactory` / `QieForgePair` / `QieForgeRouter`) plus an
over-collateralized lending vault (`QieForgeVault`) — built for **QIE Mainnet
Hackathon 3.0** (Developer Infrastructure & Tooling periphery, DeFi &
Financial Infrastructure track for the protocol itself; see
[`docs/HACKATHON.md`](docs/HACKATHON.md)).

**Judges: start with [`SUBMISSION.md`](SUBMISSION.md)** — the 5-minute
judge-facing summary (problem, what's built, live demo walkthrough, real
findings, security fixes, judging-criteria mapping, and the one honest
open gap). [`docs/DEMO-SCRIPT.md`](docs/DEMO-SCRIPT.md) is the demo-video
walkthrough script and [`docs/TEAM-PRESENTATION.md`](docs/TEAM-PRESENTATION.md)
is the team presentation.

QIE Forge also ships a typed TypeScript SDK (`@qie-forge/core`) and a small
CLI (`@qie-forge/cli`) used to build, deploy, and operate the protocol — and,
along the way, to independently verify several things about QIE's own public
documentation that turned out to be wrong or outdated. See
[Real findings](#real-findings-from-building-this) below; this is not a
claim made in the abstract — every one of them is backed by an actual
on-chain call you can re-run yourself.

## What's in this repo

```
packages/
  contracts/   Foundry project — the real protocol (Solidity, tested)
  core/        @qie-forge/core — TypeScript SDK (viem-based RPC/oracle/explorer client)
  cli/         @qie-forge/cli  — CLI built on @qie-forge/core
  python/      qie_forge       — Python SDK (web3.py), 23/23 tests incl. a real anvil deployment
  rust/        qie-forge       — Rust SDK (ethers-rs), 15/15 tests
apps/
  web/         Next.js frontend — live at https://qie-forge.vercel.app
```

## The protocol (`packages/contracts`)

Clean-room constant-product AMM + isolated lending vault, written from first
principles for QIE Forge — no existing DEX/lending protocol's source was
read or copied while building this (see each contract's NatSpec for the
derivation of its formulas).

- **`QieForgeFactory`** — CREATE2 factory, one `QieForgePair` per token pair, optional protocol-fee switch.
- **`QieForgePair`** — constant-product (`x*y=k`) pool, 30bps swap fee compounding into reserves, minimum-liquidity burn-lock, price-cumulative TWAP accumulators, ERC-20 LP shares.
- **`QieForgeRouter`** — multi-hop swap routing, add/remove liquidity with slippage + deadline protection.
- **`QieOracleAdapter`** — normalizes QIE's real on-chain price oracles (see below) into an 18-decimal USD price, fails closed if an asset has no configured feed or the price is stale.
- **`QieForgeVault`** — over-collateralized borrowing against a single collateral asset: deposit, borrow up to an LTV cap, real-time health-factor computation, permissionless liquidation with a liquidation bonus, simple per-second interest accrual.

```bash
cd packages/contracts
forge install   # fetches forge-std + OpenZeppelin if lib/ isn't already vendored
forge build
forge test -vv
```

43/43 tests pass locally against Foundry's EVM (deterministic, no network
dependency), including 3-pool multi-hop routing, exact-output swaps, oracle
staleness/decimals/rotation edge cases, liquidation edge cases (zero-debt,
over-repay, partial liquidation, sequential liquidators), and lender
deposit/withdraw share accounting — see [STATUS.md](docs/STATUS.md) for the
actual `forge test` output.

## The SDK + CLI (`packages/core`, `packages/cli`)

```bash
npm install
npm run build
node packages/cli/dist/index.js chain-info --network testnet
node packages/cli/dist/index.js oracle-price --network mainnet --asset BTC
```

`@qie-forge/core` exports a typed `ChainClient` (viem-based, chain-ID
verifying), `OracleClient` (the real oracle interface, see below),
`QusdcClient` (fails closed — QUSDC's contract address is not independently
confirmed, see [`src/qusdc.ts`](packages/core/src/qusdc.ts)),
`ExplorerClient` (wraps QIE's existing Blockscout-family explorer instead of
re-indexing anything), and typed QIE Wallet connection constants.

Live unit tests: `npm run test -w packages/core` (offline-safe). Live
integration tests against the real testnet/mainnet RPCs and explorer API:
`npm run test:live -w packages/core` — gated behind
`QIE_FORGE_RUN_LIVE_TESTS=1` so normal test runs stay fast and
network-independent.

## The Python and Rust SDKs (`packages/python`, `packages/rust`)

Both mirror `@qie-forge/core`'s chain/oracle/qusdc/amm logic in their own
idiomatic form (web3.py / ethers-rs), not a thin wrapper around the
TypeScript package.

```bash
# Python
cd packages/python && python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest -q                              # 15 offline-safe (incl. 2 real anvil-deployment tests)
QIE_FORGE_RUN_LIVE_TESTS=1 pytest -q   # + 8 live against real testnet/mainnet

# Rust
cd packages/rust
cargo test                                               # 9 offline-safe + 2 anvil-deployment integration tests
QIE_FORGE_RUN_LIVE_TESTS=1 cargo test --test live_chain  # + 4 live against real testnet/mainnet
```

Both the Python (`tests/test_anvil_integration.py`) and Rust
(`tests/anvil_integration.rs`) SDKs deploy the actual compiled
`packages/contracts` bytecode to a local anvil devnet and prove their
`VaultClient`/`amm` read/quote logic matches real on-chain state exactly —
not a mock. 23/23 Python tests and 15/15 Rust tests pass. See
[docs/STATUS.md](docs/STATUS.md) for the full breakdown.

## The frontend (`apps/web`)

**Live at https://qie-forge.vercel.app.** Next.js 16 + viem, no wallet-
connector framework — QIE Wallet's own docs specify a plain injected
EIP-1193/EIP-6963 provider, so that's what `lib/wallet.ts` talks to
directly. The home page is a server component calling `@qie-forge/core`
on every request (real live testnet/mainnet block numbers, real BTC/QIE
oracle prices — no caching, no fixtures). `/swap` and `/vault` render an
honest "not deployed on this network yet" state until the
`NEXT_PUBLIC_QIE_FORGE_*_ADDRESS` env vars point at a real deployment —
proven to work correctly against one: this session deployed the real
contracts to a local anvil devnet and confirmed the frontend's `/api/quote`
route returned the exact same quote as a direct `cast call` to the
deployed router. See [docs/STATUS.md](docs/STATUS.md) for the full detail,
including the one honest gap (no real-browser wallet click-through test).

## Real findings from building this (2026-10-26)

Everything below came from an actual `eth_call`/`eth_getCode`/HTTP request
made while building this repo, not from re-reading docs harder.

1. **The testnet RPC URL this ecosystem's own prior documentation pointed
   at is dead.** `https://rpc1testnet.qie.digital/` returned
   `ECONNREFUSED`. The real, working testnet RPC is
   **`https://testnet.qie.digital/api/eth-rpc`** — QIE's own Blockscout
   explorer's JSON-RPC proxy — confirmed via a real `eth_chainId` call
   (`0x7bf` = 1983) and a real current block number. `@qie-forge/core`
   defaults to the working URL and makes both overridable via env vars so
   this can't silently break again.
2. **QIE's own Oracle developer docs describe a function that doesn't
   exist.** `docs.qie.digital/qie-oracle` documents `getPrice(string)`.
   Calling it on the real deployed BTC oracle
   (`0x9E596d809a20A272c788726f592c0d1629755440`, Mainnet) **reverts**.
   The actual deployed bytecode is a Chainlink `AggregatorV3Interface`
   clone — confirmed live: `decimals()` → `8`, `description()` →
   `"BTC / USDT"`, `latestRoundData()` → a real non-zero round. `qie-forge
   oracle-price --network mainnet --asset BTC` reads it correctly today.
3. **The oracle is Mainnet-only.** The same 7 published addresses
   (BTC/ETH/XRP/SOL/QIE/XAUt/BNB) have real bytecode on Mainnet but
   `eth_getCode` returns `"0x"` (nothing deployed) at the same addresses on
   Testnet. `OracleClient`/`QieOracleAdapter` both fail closed instead of
   guessing.
4. **No general-purpose QIE developer SDK existed before this.** `qieadmin`'s
   public repos include only single-protocol JS SDKs (`qie-lend-sdk`,
   `qusdc-sdk`) — no CLI, no multi-language clients.
5. **QUSDC's ERC-20 contract address is still not independently
   confirmed** anywhere public. `QusdcClient` requires
   `QIE_FORGE_QUSDC_ADDRESS` with no default and throws rather than
   guessing.

## Status (honest, see [docs/STATUS.md](docs/STATUS.md) for the full breakdown)

See [SUBMISSION.md](SUBMISSION.md) for the judge-facing 5-minute summary of
everything below, including the judging-criteria mapping and the one
real open gap.

- **Live and public**: https://qie-forge.vercel.app, serving real on-chain
  data on every request, including a real self-hosted demo deployment behind
  `/swap` and `/vault`.
- **Built and verified live**: TypeScript, Python, and Rust SDKs + the CLI,
  all against real testnet/mainnet RPCs and the real oracle contracts.
- **Built and verified locally**: the full AMM + lending vault contract
  suite (43/43 Foundry tests); both the Python and Rust SDKs' read/quote
  logic against a real local deployment of the actual contract bytecode
  (anvil); the frontend's quote/vault-position APIs against that same real
  deployment, now also publicly reachable (see SUBMISSION.md).
- **Not yet done**: an actual on-chain QIE Testnet/Mainnet deployment of the
  protocol contracts — blocked on a funded deployer wallet (QIE's testnet
  faucet is a connect-a-wallet flow, not a plain API, so claiming testnet or
  mainnet QIE for a deployer key is a real owner/operator step); a
  real-browser wallet click-through test for the frontend.

## License

MIT.
