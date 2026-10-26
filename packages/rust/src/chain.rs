//! Thin, typed wrapper around QIE's EVM JSON-RPC surface — mirrors
//! packages/core/src/chain.ts. QIE exposes standard eth_* methods, so this
//! reuses `ethers-rs`'s battle-tested provider rather than hand-rolling
//! JSON-RPC framing.

use std::str::FromStr;

use ethers::prelude::*;

use crate::errors::QieForgeError;
use crate::networks::{resolve_network, QieNetwork, QieNetworkConfig};

#[derive(Debug, Clone)]
pub struct ChainSnapshot {
    pub network: &'static str,
    pub chain_id: u64,
    pub block_number: u64,
    pub block_hash: String,
    pub timestamp: u64,
    pub gas_price: U256,
}

pub struct ChainClient {
    pub config: QieNetworkConfig,
    provider: Provider<Http>,
}

impl ChainClient {
    pub fn new(network: &QieNetwork, rpc_url_override: Option<String>) -> Result<Self, QieForgeError> {
        let config = resolve_network(network, rpc_url_override);
        let provider = Provider::<Http>::try_from(config.rpc_url.as_str())
            .map_err(|e| QieForgeError::NetworkUnreachable(format!("{}: {e}", config.rpc_url)))?;
        Ok(Self { config, provider })
    }

    /// For non-standard networks (e.g. a local anvil devnet in integration
    /// tests), not one of QIE's real networks.
    pub fn from_config(config: QieNetworkConfig) -> Result<Self, QieForgeError> {
        let provider = Provider::<Http>::try_from(config.rpc_url.as_str())
            .map_err(|e| QieForgeError::NetworkUnreachable(format!("{}: {e}", config.rpc_url)))?;
        Ok(Self { config, provider })
    }

    pub fn provider(&self) -> &Provider<Http> {
        &self.provider
    }

    pub async fn verify_chain_id(&self) -> Result<u64, QieForgeError> {
        let chain_id = self
            .provider
            .get_chainid()
            .await
            .map_err(|e| QieForgeError::NetworkUnreachable(format!("{}: {e}", self.config.rpc_url)))?
            .as_u64();

        if chain_id != self.config.chain_id {
            return Err(QieForgeError::InvalidResponse(format!(
                "RPC at {} returned chain ID {chain_id}, expected {} ({}). Refusing to proceed on a mismatched network.",
                self.config.rpc_url, self.config.chain_id, self.config.name
            )));
        }
        Ok(chain_id)
    }

    pub async fn get_snapshot(&self) -> Result<ChainSnapshot, QieForgeError> {
        let chain_id = self.verify_chain_id().await?;
        let block = self
            .provider
            .get_block(BlockNumber::Latest)
            .await
            .map_err(|e| QieForgeError::NetworkUnreachable(e.to_string()))?
            .ok_or_else(|| QieForgeError::InvalidResponse("latest block was null".into()))?;
        let gas_price = self
            .provider
            .get_gas_price()
            .await
            .map_err(|e| QieForgeError::NetworkUnreachable(e.to_string()))?;

        Ok(ChainSnapshot {
            network: self.config.name,
            chain_id,
            block_number: block.number.map(|n| n.as_u64()).unwrap_or_default(),
            block_hash: block.hash.map(|h| format!("{h:#x}")).unwrap_or_default(),
            timestamp: block.timestamp.as_u64(),
            gas_price,
        })
    }

    pub async fn get_balance(&self, address: &str) -> Result<U256, QieForgeError> {
        let addr = self.parse_address(address)?;
        self.provider
            .get_balance(addr, None)
            .await
            .map_err(|e| QieForgeError::NetworkUnreachable(e.to_string()))
    }

    pub async fn get_code(&self, address: &str) -> Result<Bytes, QieForgeError> {
        let addr = self.parse_address(address)?;
        self.provider
            .get_code(addr, None)
            .await
            .map_err(|e| QieForgeError::NetworkUnreachable(e.to_string()))
    }

    pub async fn is_contract_deployed(&self, address: &str) -> Result<bool, QieForgeError> {
        Ok(!self.get_code(address).await?.0.is_empty())
    }

    fn parse_address(&self, address: &str) -> Result<Address, QieForgeError> {
        Address::from_str(address).map_err(|_| QieForgeError::InvalidAddress(address.to_string()))
    }
}
