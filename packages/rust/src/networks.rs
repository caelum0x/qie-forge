//! Network configs — mirrors packages/core/src/networks.ts exactly: same
//! verified endpoints, same env-override posture. Hosted RPC URLs on this
//! chain have already moved once (see README) — never hardcode trust in a
//! single endpoint without an override path.

use crate::errors::QieForgeError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QieNetwork {
    Testnet,
    Mainnet,
}

#[derive(Debug, Clone)]
pub struct QieNetworkConfig {
    pub name: &'static str,
    pub chain_id: u64,
    pub rpc_url: String,
    pub explorer_url: &'static str,
    pub explorer_api_url: &'static str,
}

impl QieNetwork {
    pub fn parse(name: &str) -> Result<Self, QieForgeError> {
        match name {
            "testnet" => Ok(QieNetwork::Testnet),
            "mainnet" => Ok(QieNetwork::Mainnet),
            other => Err(QieForgeError::UnsupportedNetwork(format!(
                "\"{other}\". Supported: testnet, mainnet"
            ))),
        }
    }
}

/// Resolves a network config, honoring env overrides
/// (`QIE_FORGE_TESTNET_RPC_URL` / `QIE_FORGE_MAINNET_RPC_URL`) and an
/// explicit override, in that precedence order — same as the TS/Python SDKs.
pub fn resolve_network(network: &QieNetwork, rpc_url_override: Option<String>) -> QieNetworkConfig {
    match network {
        QieNetwork::Testnet => {
            let default_url = "https://testnet.qie.digital/api/eth-rpc".to_string();
            let env_url = std::env::var("QIE_FORGE_TESTNET_RPC_URL").ok();
            QieNetworkConfig {
                name: "testnet",
                chain_id: 1983,
                rpc_url: rpc_url_override.or(env_url).unwrap_or(default_url),
                explorer_url: "https://testnet.qie.digital",
                explorer_api_url: "https://testnet.qie.digital/api",
            }
        }
        QieNetwork::Mainnet => {
            let default_url = "https://rpc1mainnet.qie.digital".to_string();
            let env_url = std::env::var("QIE_FORGE_MAINNET_RPC_URL").ok();
            QieNetworkConfig {
                name: "mainnet",
                chain_id: 1990,
                rpc_url: rpc_url_override.or(env_url).unwrap_or(default_url),
                explorer_url: "https://mainnet.qie.digital",
                explorer_api_url: "https://mainnet.qie.digital/api",
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::sync::Mutex;

    // `std::env::set_var`/`remove_var` mutate real process-wide state, and
    // `cargo test` runs tests in this module on separate threads by
    // default — without serializing the two tests that touch
    // `QIE_FORGE_TESTNET_RPC_URL`, `default_rpc_urls_match_verified_endpoints`
    // can observe the env var `explicit_override_wins_over_env` set in a
    // concurrently-running thread (confirmed flaky via repeated `cargo
    // test` runs). This lock makes that env mutation section exclusive.
    static ENV_VAR_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn default_rpc_urls_match_verified_endpoints() {
        let _guard = ENV_VAR_TEST_LOCK.lock().unwrap();
        let testnet = resolve_network(&QieNetwork::Testnet, None);
        assert_eq!(testnet.rpc_url, "https://testnet.qie.digital/api/eth-rpc");
        assert_eq!(testnet.chain_id, 1983);

        let mainnet = resolve_network(&QieNetwork::Mainnet, None);
        assert_eq!(mainnet.rpc_url, "https://rpc1mainnet.qie.digital");
        assert_eq!(mainnet.chain_id, 1990);
    }

    #[test]
    fn explicit_override_wins_over_env() {
        let _guard = ENV_VAR_TEST_LOCK.lock().unwrap();
        env::set_var("QIE_FORGE_TESTNET_RPC_URL", "https://env.example/");
        let resolved = resolve_network(&QieNetwork::Testnet, Some("https://explicit.example/".into()));
        assert_eq!(resolved.rpc_url, "https://explicit.example/");
        env::remove_var("QIE_FORGE_TESTNET_RPC_URL");
    }

    #[test]
    fn unsupported_network_name_rejected() {
        assert!(QieNetwork::parse("devnet").is_err());
    }
}
