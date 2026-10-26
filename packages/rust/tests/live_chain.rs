//! Hits the REAL QIE testnet and mainnet RPCs. Gated behind
//! QIE_FORGE_RUN_LIVE_TESTS=1 (checked at runtime, matching the TS/Python
//! SDKs' split) rather than `#[ignore]`, so the same env var drives all
//! three SDKs' live tests.

use qie_forge::{ChainClient, OracleClient, QieNetwork};

fn live_enabled() -> bool {
    std::env::var("QIE_FORGE_RUN_LIVE_TESTS").as_deref() == Ok("1")
}

#[tokio::test]
async fn testnet_chain_id_and_block_floor() {
    if !live_enabled() {
        eprintln!("skipping: set QIE_FORGE_RUN_LIVE_TESTS=1");
        return;
    }
    let client = ChainClient::new(&QieNetwork::Testnet, None).unwrap();
    let snapshot = client.get_snapshot().await.unwrap();
    assert_eq!(snapshot.chain_id, 1983);
    assert!(snapshot.block_number > 9_000_000);
}

#[tokio::test]
async fn mainnet_chain_id_and_block_floor() {
    if !live_enabled() {
        eprintln!("skipping: set QIE_FORGE_RUN_LIVE_TESTS=1");
        return;
    }
    let client = ChainClient::new(&QieNetwork::Mainnet, None).unwrap();
    let snapshot = client.get_snapshot().await.unwrap();
    assert_eq!(snapshot.chain_id, 1990);
    assert!(snapshot.block_number > 11_000_000);
}

#[tokio::test]
async fn mainnet_btc_oracle_price_is_real_and_positive() {
    if !live_enabled() {
        eprintln!("skipping: set QIE_FORGE_RUN_LIVE_TESTS=1");
        return;
    }
    let client = ChainClient::new(&QieNetwork::Mainnet, None).unwrap();
    let oracle = OracleClient::new(&client, vec!["mainnet"]);
    let result = oracle.get_price("BTC").await.unwrap();
    assert!(result.answer > 0);
    assert_eq!(result.decimals, 8);
    assert!(result.description.to_uppercase().contains("BTC"));
}

#[tokio::test]
async fn testnet_oracle_fails_closed_instead_of_guessing() {
    if !live_enabled() {
        eprintln!("skipping: set QIE_FORGE_RUN_LIVE_TESTS=1");
        return;
    }
    let client = ChainClient::new(&QieNetwork::Testnet, None).unwrap();
    let oracle = OracleClient::new(&client, vec!["testnet"]);
    let err = oracle.get_price("BTC").await.unwrap_err();
    assert!(matches!(err, qie_forge::QieForgeError::OracleNotDeployed(_)));
}
