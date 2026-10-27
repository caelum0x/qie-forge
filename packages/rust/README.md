# qie-forge (Rust SDK)

Rust client (`ethers-rs`-based) mirroring `@qie-forge/core` / the Python
`qie_forge` package: a real chain client, the real (corrected) QIE Oracle
ABI via `abigen!`, a fail-closed QUSDC helper, pure AMM quote math, an
on-chain reserve-reading/quote path (`get_reserves`/`get_amounts_out_onchain`),
unsigned swap-tx building, and a read-only `VaultClient`.

## Build & test

```bash
cargo build
cargo test                                   # unit + local-anvil integration tests
QIE_FORGE_RUN_LIVE_TESTS=1 cargo test --test live_chain -- --nocapture
```

- `src/amm.rs`, `src/networks.rs`, `src/qusdc.rs` — unit tests (`#[cfg(test)] mod tests`), no network.
- `tests/anvil_integration.rs` — deploys the REAL compiled `packages/contracts` bytecode (`MockERC20` ×2, `MockAggregatorV3` ×2, `QieOracleAdapter`, `QieForgeVault`, `QieForgeFactory`, `QieForgeRouter` — loaded straight from `forge build`'s own `out/` artifacts, never re-implemented) to a local anvil devnet via `ethers-rs`'s `ContractFactory`, then proves the Rust SDK's `VaultClient::get_position()` matches a hand-calculated health factor and `get_amounts_out_onchain()` matches the deployed router's own `getAmountsOut()` call exactly, and that the unsigned tx `build_swap_exact_tokens_for_tokens_tx()` builds actually executes on-chain. Requires `anvil` (Foundry) on `PATH`; skips cleanly (prints a message, does not fail) if it isn't installed. Mirrors `packages/python/tests/test_anvil_integration.py`'s exact pattern and rigor.
- `tests/live_chain.rs` — real calls against `https://testnet.qie.digital/api/eth-rpc` (chain 1983) and `https://rpc1mainnet.qie.digital` (chain 1990), gated behind `QIE_FORGE_RUN_LIVE_TESTS=1` checked at runtime (tests no-op cleanly without it, so `cargo test` alone stays offline-safe).

15/15 tests pass as of 2026-10-27 (9 unit + 2 local-anvil integration + 4 live-stub). The two anvil tests share a process-wide mutex so they run sequentially even under `cargo test`'s default per-binary thread concurrency — each spins up its own real anvil devnet and sends several real transactions, and running both at once was observed to occasionally starve one node's RPC responsiveness on a loaded machine (a resource-contention flake, not a logic bug).

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

```rust
use qie_forge::vault::VaultClient;
use qie_forge::{ChainClient, QieNetwork};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let chain = ChainClient::new(&QieNetwork::Mainnet, None)?;
    let vault = VaultClient::new(&chain, "0x0000000000000000000000000000000000000000")?;
    let position = vault.get_position("0x0000000000000000000000000000000000000000").await?;
    println!("{position:?}");
    Ok(())
}
```

## Known scope gaps

None remaining as of 2026-10-27: `tests/anvil_integration.rs` closed the
local-anvil contract-deployment gap tracked here and in `docs/STATUS.md` —
the Rust SDK now has the same proof the Python SDK had (see "Build & test"
above).
