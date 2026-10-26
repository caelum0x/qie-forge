//! QIE Oracle client — mirrors packages/core/src/oracle.ts and
//! packages/python/qie_forge/oracle.py exactly, including the real,
//! independently-verified ABI correction: QIE's own docs describe
//! `getPrice(string) view returns (uint256)`, which reverts on the real
//! deployed contracts. The actual deployed bytecode is a Chainlink
//! `AggregatorV3Interface` clone (confirmed live via eth_call on
//! 2026-10-26). This client uses the REAL interface.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;

use ethers::prelude::*;

use crate::chain::ChainClient;
use crate::errors::QieForgeError;

abigen!(
    IQieOracleAggregator,
    r#"[
        function decimals() external view returns (uint8)
        function description() external view returns (string)
        function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    ]"#
);

/// Published at docs.qie.digital/qie-oracle/deployed-contracts, confirmed
/// live via eth_getCode + a real latestRoundData() call on Mainnet only.
pub fn oracle_addresses() -> HashMap<&'static str, &'static str> {
    HashMap::from([
        ("BTC", "0x9E596d809a20A272c788726f592c0d1629755440"),
        ("ETH", "0x4bb7012Fbc79fE4Ae9B664228977b442b385500d"),
        ("XRP", "0x804582B1f8Fea73919e7c737115009f668f97528"),
        ("SOL", "0xe86999c8e6C8eeF71bebd35286bCa674E0AD7b21"),
        ("QIE", "0x3Bc617cF3A4Bb77003e4c556B87b13D556903D17"),
        ("XAUt", "0x9aD0199a67588ee293187d26bA1BE61cb07A214c"),
        ("BNB", "0x775A56117Fdb8b31877E75Ceeb68C96765b031e6"),
    ])
}

#[derive(Debug, Clone)]
pub struct OraclePriceResult {
    pub asset: String,
    pub network: &'static str,
    pub contract_address: Address,
    pub description: String,
    pub decimals: u8,
    pub round_id: u128,
    pub answer: i128,
    pub updated_at: u64,
}

impl OraclePriceResult {
    pub fn human_price(&self) -> f64 {
        self.answer as f64 / 10f64.powi(self.decimals as i32)
    }
}

pub struct OracleClient<'a> {
    chain: &'a ChainClient,
    deployed_networks: Vec<&'static str>,
}

impl<'a> OracleClient<'a> {
    pub fn new(chain: &'a ChainClient, deployed_networks: Vec<&'static str>) -> Self {
        Self { chain, deployed_networks }
    }

    pub fn get_contract_address(&self, asset: &str) -> Result<Address, QieForgeError> {
        let addresses = oracle_addresses();
        let addr = addresses.get(asset).ok_or_else(|| {
            let supported: Vec<&str> = addresses.keys().copied().collect();
            QieForgeError::OracleAssetUnsupported(format!(
                "\"{asset}\" has no known QIE Oracle contract. Supported: {}",
                supported.join(", ")
            ))
        })?;
        Address::from_str(addr).map_err(|_| QieForgeError::InvalidAddress(addr.to_string()))
    }

    pub async fn get_price(&self, asset: &str) -> Result<OraclePriceResult, QieForgeError> {
        let address = self.get_contract_address(asset)?;
        let network = self.chain.config.name;

        if !self.deployed_networks.contains(&network) {
            return Err(QieForgeError::OracleNotDeployed(format!(
                "\"{asset}\" is not configured as deployed on \"{network}\" (allowlist is {:?}). \
                 Verified live 2026-10-26: real bytecode on Mainnet (1990), empty bytecode on Testnet (1983).",
                self.deployed_networks
            )));
        }

        let deployed = self.chain.is_contract_deployed(&format!("{address:#x}")).await?;
        if !deployed {
            return Err(QieForgeError::OracleNotDeployed(format!(
                "eth_getCode returned no bytecode for the {asset} oracle at {address:#x} on {network}."
            )));
        }

        let contract = IQieOracleAggregator::new(address, Arc::new(self.chain.provider().clone()));
        let decimals: u8 = contract
            .decimals()
            .call()
            .await
            .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let description: String = contract
            .description()
            .call()
            .await
            .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let (round_id, answer, _started_at, updated_at, _answered_in_round) = contract
            .latest_round_data()
            .call()
            .await
            .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;

        if answer <= I256::zero() {
            return Err(QieForgeError::InvalidResponse(format!(
                "QIE Oracle for {asset} returned a non-positive answer ({answer})."
            )));
        }

        Ok(OraclePriceResult {
            asset: asset.to_string(),
            network,
            contract_address: address,
            description,
            decimals,
            round_id,
            answer: answer.as_i128(),
            updated_at: updated_at.as_u64(),
        })
    }
}
