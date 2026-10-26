# qie-forge (Rust SDK)

Rust client (`ethers-rs`-based) mirroring `@qie-forge/core` / the Python
`qie_forge` package: a real chain client, the real (corrected) QIE Oracle
ABI via `abigen!`, a fail-closed QUSDC helper, and pure AMM quote math.

## Build & test

```bash
cargo build
cargo test                                   # unit tests, offline-safe
QIE_FORGE_RUN_LIVE_TESTS=1 cargo test --test live_chain -- --nocapture
```

- `src/amm.rs`, `src/networks.rs`, `src/qusdc.rs` — unit tests (`#[cfg(test)] mod tests`), no network.
- `tests/live_chain.rs` — real calls against `https://testnet.qie.digital/api/eth-rpc` (chain 1983) and `https://rpc1mainnet.qie.digital` (chain 1990), gated behind `QIE_FORGE_RUN_LIVE_TESTS=1` checked at runtime (tests no-op cleanly without it, so `cargo test` alone stays offline-safe).

13/13 tests pass as of 2026-10-26 (9 unit + 4 live).

## Usage

```rust
use qie_forge::{ChainClient, OracleClient, QieNetwork};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let chain = ChainClient::new(&QieNetwork::Mainnet, None)?;
    let snapshot = chain.get_snapshot().await?;
    println!("{snapshot:?}");

    let oracle = OracleClient::new(&chain, vec!["mainnet"]);
    let btc = oracle.get_price("BTC").await?;
    println!("{} = ${:.2} ({})", btc.asset, btc.human_price(), btc.description);
    Ok(())
}
```

## Known scope gap

No local-anvil contract-deployment integration test yet (the Python SDK has
one — see `packages/python/tests/test_anvil_integration.py` — deploying the
real compiled contracts and reading a vault position / building a swap tx
against them). Not implemented here due to session time; `amm.rs`'s quote
math is covered by unit tests only, not an on-chain round-trip. Tracked
honestly in `docs/STATUS.md`, not claimed as done.
