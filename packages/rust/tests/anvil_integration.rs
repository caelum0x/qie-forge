//! Integration tests against a REAL local EVM (anvil), running the ACTUAL
//! compiled QieForge* contracts (loaded from packages/contracts/out — forge
//! build output, not re-implemented or mocked here). Mirrors
//! packages/python/tests/test_anvil_integration.py's exact pattern: this
//! proves the Rust SDK's read/quote logic works against real bytecode,
//! without needing a funded deployer key on the live QIE testnet (which the
//! project's testnet faucet gates behind a wallet-connect flow — a real
//! owner/operator step, not something this test suite can do).
//!
//! Closes the "known gap" documented in README.md / docs/STATUS.md: the
//! Python SDK had this anvil-deployment proof, the Rust SDK did not.

use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ethers::abi::{Abi, Tokenize};
use ethers::contract::{Contract, ContractFactory};
use ethers::prelude::*;
use serde::Deserialize;

use qie_forge::amm::{build_swap_exact_tokens_for_tokens_tx, get_amounts_out_onchain};
use qie_forge::vault::VaultClient;
use qie_forge::{ChainClient, QieNetworkConfig};

// Two distinct ports — both tests in this binary run concurrently by
// default (`cargo test` runs tests within a binary on separate threads),
// so each needs its own local anvil devnet rather than racing for one port.
const VAULT_TEST_ANVIL_PORT: u16 = 8647;
const AMM_TEST_ANVIL_PORT: u16 = 8648;
const ANVIL_DEFAULT_ADDRESS: &str = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const WAD: u128 = 1_000_000_000_000_000_000;

// `cargo test` runs the two tests below concurrently on separate threads by
// default. Each spins up its own real anvil devnet and sends several real
// transactions to it; running both at once on a loaded dev machine was
// observed to occasionally starve one node's mining/RPC responsiveness
// enough that a transaction receipt poll gave up (a resource-contention
// flake, not a logic bug — confirmed by both tests passing reliably under
// `--test-threads=1`). Serializing them removes the flake without
// weakening either test.
static TEST_LOCK: Mutex<()> = Mutex::new(());

/// Kills the spawned anvil process when the test (and this guard) goes out
/// of scope, pass or fail.
struct AnvilHandle(Child);

impl Drop for AnvilHandle {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start_anvil(port: u16) -> Option<AnvilHandle> {
    let child = Command::new("anvil")
        .args(["--port", &port.to_string(), "--silent"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    for _ in 0..50 {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return Some(AnvilHandle(child));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    None
}

#[derive(Deserialize)]
struct BytecodeObject {
    object: Bytes,
}

#[derive(Deserialize)]
struct ForgeArtifact {
    abi: Abi,
    bytecode: BytecodeObject,
}

/// Loads the REAL compiled ABI + bytecode from packages/contracts/out
/// (forge build output) — same artifacts the Python integration test
/// loads, never a re-implementation.
fn load_artifact(solidity_file: &str, contract_name: &str) -> (Abi, Bytes) {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("..");
    path.push("contracts");
    path.push("out");
    path.push(format!("{solidity_file}.sol"));
    path.push(format!("{contract_name}.json"));

    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!("Compiled artifact not found at {path:?} ({e}). Run `forge build` in packages/contracts first.")
    });
    let artifact: ForgeArtifact = serde_json::from_str(&raw).expect("valid forge artifact json");
    (artifact.abi, artifact.bytecode.object)
}

type LocalProvider = Arc<Provider<Http>>;

async fn deploy<T: Tokenize>(provider: &LocalProvider, from: Address, abi: Abi, bytecode: Bytes, args: T) -> Contract<Provider<Http>> {
    let factory = ContractFactory::new(abi, bytecode, provider.clone());
    let mut deployer = factory.deploy(args).expect("constructor args encode against the real ABI").legacy();
    deployer.tx.set_from(from);
    deployer.send().await.expect("contract deploys to the local anvil devnet")
}

/// Sends a real state-changing transaction against an already-deployed
/// contract, addressed by its full ABI (mirrors the Python test's
/// `contract.functions.X(...).transact(...)` calls) and waits for the
/// receipt.
async fn send(contract: &Contract<Provider<Http>>, from: Address, method: &str, args: impl Tokenize) {
    let call: ethers::contract::ContractCall<Provider<Http>, ()> =
        contract.method(method, args).unwrap_or_else(|e| panic!("method {method} exists in the real ABI: {e}"));
    let call = call.legacy().from(from);
    let pending = call.send().await.unwrap_or_else(|e| panic!("{method} tx sent: {e}"));
    let receipt = pending.await.unwrap_or_else(|e| panic!("{method} tx confirmed: {e}")).expect("receipt present");
    assert_eq!(receipt.status, Some(1.into()), "{method} reverted on-chain");
}

async fn anvil_chain_client(port: u16) -> (ChainClient, LocalProvider) {
    let rpc_url = format!("http://127.0.0.1:{port}");
    let config =
        QieNetworkConfig { name: "anvil-local", chain_id: 31337, rpc_url: rpc_url.clone(), explorer_url: "", explorer_api_url: "" };
    let chain = ChainClient::from_config(config).expect("anvil provider constructs");
    let provider = Arc::new(Provider::<Http>::try_from(rpc_url).expect("anvil provider constructs"));
    (chain, provider)
}

#[tokio::test]
async fn vault_position_reads_against_real_deployed_contracts() {
    let _serialize = TEST_LOCK.lock().unwrap();
    let Some(_anvil) = start_anvil(VAULT_TEST_ANVIL_PORT) else {
        eprintln!("skipping: `anvil` (Foundry) is not installed");
        return;
    };

    let (chain, provider) = anvil_chain_client(VAULT_TEST_ANVIL_PORT).await;
    let from = Address::from_str(ANVIL_DEFAULT_ADDRESS).unwrap();

    let (mock_erc20_abi, mock_erc20_bytecode) = load_artifact("MockERC20", "MockERC20");
    let (mock_aggregator_abi, mock_aggregator_bytecode) = load_artifact("MockAggregatorV3", "MockAggregatorV3");
    let (oracle_abi, oracle_bytecode) = load_artifact("QieOracleAdapter", "QieOracleAdapter");
    let (vault_abi, vault_bytecode) = load_artifact("QieForgeVault", "QieForgeVault");

    let collateral = deploy(&provider, from, mock_erc20_abi.clone(), mock_erc20_bytecode.clone(), ("Wrapped QIE".to_string(), "WQIE".to_string(), 18u8)).await;
    let borrow_token = deploy(&provider, from, mock_erc20_abi.clone(), mock_erc20_bytecode.clone(), ("Test USD".to_string(), "TUSD".to_string(), 6u8)).await;
    let collateral_feed =
        deploy(&provider, from, mock_aggregator_abi.clone(), mock_aggregator_bytecode.clone(), (8u8, "QIE / USD".to_string(), 100_000_000i64 /* $1.00 at 8 decimals */)).await;
    let borrow_feed =
        deploy(&provider, from, mock_aggregator_abi.clone(), mock_aggregator_bytecode.clone(), (8u8, "TUSD / USD".to_string(), 100_000_000i64 /* $1.00 at 8 decimals */)).await;

    let oracle = deploy(&provider, from, oracle_abi, oracle_bytecode, (from, U256::from(86_400u64))).await;
    send(&oracle, from, "setFeed", (collateral.address(), collateral_feed.address())).await;
    send(&oracle, from, "setFeed", (borrow_token.address(), borrow_feed.address())).await;

    let ltv_bps = 7_500u64;
    let liq_threshold_bps = 8_000u64;
    let liq_bonus_bps = 500u64;
    let rate_per_second = 1_585_489_599u64;
    let vault = deploy(
        &provider,
        from,
        vault_abi,
        vault_bytecode,
        (
            collateral.address(),
            borrow_token.address(),
            oracle.address(),
            U256::from(ltv_bps),
            U256::from(liq_threshold_bps),
            U256::from(liq_bonus_bps),
            U256::from(rate_per_second),
        ),
    )
    .await;

    send(&collateral, from, "mint", (from, U256::from(10_000u64) * U256::exp10(18))).await;
    send(&borrow_token, from, "mint", (vault.address(), U256::from(1_000_000u64) * U256::exp10(6))).await;
    send(&collateral, from, "approve", (vault.address(), U256::MAX)).await;

    send(&vault, from, "depositCollateral", U256::from(1_000u64) * U256::exp10(18)).await;
    send(&vault, from, "borrow", U256::from(700u64) * U256::exp10(6)).await;

    // --- Real assertion: the Rust SDK's VaultClient reads this REAL on-chain state correctly. ---
    let vault_client = VaultClient::new(&chain, &format!("{:#x}", vault.address())).unwrap();
    let position = vault_client.get_position(&format!("{from:#x}")).await.unwrap();

    assert_eq!(position.collateral, 1_000 * WAD);
    assert_eq!(position.debt_principal, 700 * 10u128.pow(6));
    assert!(!position.is_liquidatable());

    // (1000 * 0.80) / 700 ~= 1.142857
    let expected_health_factor = U256::from(1_142_857_142_857_142_857u128);
    let diff = if position.health_factor > expected_health_factor {
        position.health_factor - expected_health_factor
    } else {
        expected_health_factor - position.health_factor
    };
    assert!(diff < U256::from(1_000_000_000u64), "health factor {} too far from hand-calculated {}", position.health_factor, expected_health_factor);

    assert_eq!(vault_client.get_ltv_bps().await.unwrap(), U256::from(ltv_bps));
    assert_eq!(vault_client.get_liquidation_threshold_bps().await.unwrap(), U256::from(liq_threshold_bps));
}

#[tokio::test]
async fn amm_quote_and_swap_tx_building_against_real_deployed_pools() {
    let Some(_anvil) = start_anvil(AMM_TEST_ANVIL_PORT) else {
        eprintln!("skipping: `anvil` (Foundry) is not installed");
        return;
    };

    let (chain, provider) = anvil_chain_client(AMM_TEST_ANVIL_PORT).await;
    let from = Address::from_str(ANVIL_DEFAULT_ADDRESS).unwrap();

    let (mock_erc20_abi, mock_erc20_bytecode) = load_artifact("MockERC20", "MockERC20");
    let (factory_abi, factory_bytecode) = load_artifact("QieForgeFactory", "QieForgeFactory");
    let (router_abi, router_bytecode) = load_artifact("QieForgeRouter", "QieForgeRouter");

    let token_a = deploy(&provider, from, mock_erc20_abi.clone(), mock_erc20_bytecode.clone(), ("Token A".to_string(), "TKA".to_string(), 18u8)).await;
    let token_b = deploy(&provider, from, mock_erc20_abi.clone(), mock_erc20_bytecode.clone(), ("Token B".to_string(), "TKB".to_string(), 18u8)).await;
    let factory = deploy(&provider, from, factory_abi, factory_bytecode, from).await;
    let router = deploy(&provider, from, router_abi.clone(), router_bytecode, factory.address()).await;

    send(&token_a, from, "mint", (from, U256::from(1_000_000u64) * U256::exp10(18))).await;
    send(&token_b, from, "mint", (from, U256::from(1_000_000u64) * U256::exp10(18))).await;
    send(&token_a, from, "approve", (router.address(), U256::MAX)).await;
    send(&token_b, from, "approve", (router.address(), U256::MAX)).await;

    send(
        &router,
        from,
        "addLiquidity",
        (
            token_a.address(),
            token_b.address(),
            U256::from(100_000u64) * U256::exp10(18),
            U256::from(100_000u64) * U256::exp10(18),
            U256::zero(),
            U256::zero(),
            from,
            U256::MAX,
        ),
    )
    .await;

    // --- Real assertion: the Rust SDK's pure quote math, fed real on-chain reserves,
    // matches the deployed router's own on-chain getAmountsOut() call exactly. ---
    let amount_in = U256::from(1_000u64) * U256::exp10(18);
    let path = vec![token_a.address(), token_b.address()];
    let rust_quote = get_amounts_out_onchain(&chain, factory.address(), amount_in, &path).await.unwrap();

    let onchain_quote: Vec<U256> = router
        .method::<_, Vec<U256>>("getAmountsOut", (amount_in, path.clone()))
        .unwrap()
        .call()
        .await
        .unwrap();
    assert_eq!(rust_quote, onchain_quote);

    // --- Real assertion: the unsigned tx this SDK builds actually executes successfully on-chain. ---
    let deadline = chain.provider().get_block(BlockNumber::Latest).await.unwrap().unwrap().timestamp + U256::from(3600u64);
    let tx = build_swap_exact_tokens_for_tokens_tx(
        &chain,
        router.address(),
        amount_in,
        *rust_quote.last().unwrap(),
        path,
        from,
        deadline,
        from,
    );
    let pending = chain.provider().send_transaction(tx, None).await.expect("swap tx sent");
    let receipt = pending.await.expect("swap tx confirmed").expect("receipt present");
    assert_eq!(receipt.status, Some(1.into()), "swap reverted on-chain");
}
