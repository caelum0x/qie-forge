//! Read-only client for a deployed QieForgeVault — mirrors the vault's real
//! ABI (packages/contracts/src/vault/QieForgeVault.sol) and
//! packages/python/qie_forge/vault.py's `VaultClient` field-for-field. No
//! write/borrow/repay methods are included here deliberately: this SDK
//! builds unsigned transactions (see amm.rs's `build_swap_exact_tokens_for_tokens_tx`)
//! rather than ever holding or using a private key itself.

use std::str::FromStr;
use std::sync::Arc;

use ethers::prelude::*;

use crate::chain::ChainClient;
use crate::errors::QieForgeError;

abigen!(
    IQieForgeVault,
    r#"[
        function positions(address) external view returns (uint128 collateral, uint128 debtPrincipal, uint64 lastAccrual)
        function healthFactor(address user) external view returns (uint256)
        function currentDebt(address user) external view returns (uint256)
        function ltvBps() external view returns (uint256)
        function liquidationThresholdBps() external view returns (uint256)
    ]"#
);

const WAD: u64 = 1_000_000_000_000_000_000;

#[derive(Debug, Clone)]
pub struct VaultPosition {
    pub collateral: u128,
    pub debt_principal: u128,
    pub last_accrual: u64,
    pub health_factor: U256,
    pub current_debt: U256,
}

impl VaultPosition {
    pub fn is_liquidatable(&self) -> bool {
        self.debt_principal > 0 && self.health_factor < U256::from(WAD)
    }
}

pub struct VaultClient<'a> {
    chain: &'a ChainClient,
    vault_address: Address,
}

impl<'a> VaultClient<'a> {
    pub fn new(chain: &'a ChainClient, vault_address: &str) -> Result<Self, QieForgeError> {
        let vault_address =
            Address::from_str(vault_address).map_err(|_| QieForgeError::InvalidAddress(vault_address.to_string()))?;
        Ok(Self { chain, vault_address })
    }

    fn contract(&self) -> IQieForgeVault<Provider<Http>> {
        IQieForgeVault::new(self.vault_address, Arc::new(self.chain.provider().clone()))
    }

    pub async fn get_position(&self, user: &str) -> Result<VaultPosition, QieForgeError> {
        let user = Address::from_str(user).map_err(|_| QieForgeError::InvalidAddress(user.to_string()))?;
        let contract = self.contract();

        let (collateral, debt_principal, last_accrual) = contract
            .positions(user)
            .call()
            .await
            .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let health_factor = contract
            .health_factor(user)
            .call()
            .await
            .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let current_debt = contract
            .current_debt(user)
            .call()
            .await
            .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;

        Ok(VaultPosition { collateral, debt_principal, last_accrual, health_factor, current_debt })
    }

    pub async fn get_ltv_bps(&self) -> Result<U256, QieForgeError> {
        self.contract().ltv_bps().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))
    }

    pub async fn get_liquidation_threshold_bps(&self) -> Result<U256, QieForgeError> {
        self.contract()
            .liquidation_threshold_bps()
            .call()
            .await
            .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))
    }
}
