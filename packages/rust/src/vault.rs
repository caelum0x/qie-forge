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
        function liquidationBonusBpsFor(address user) external view returns (uint256)
        function totalAssets() external view returns (uint256)
        function totalReserves() external view returns (uint256)
        function protocolReserves() external view returns (uint256)
        function totalDebtPrincipal() external view returns (uint256)
        function borrowCap() external view returns (uint256)
        function reserveFactorBps() external view returns (uint256)
        function totalLenderShares() external view returns (uint256)
        function lenderShares(address user) external view returns (uint256)
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

/// Lending-pool-level stats, independent of any one borrower's own
/// position — field-for-field the same shape apps/web's `/api/vault-position`
/// route and `@qie-forge/core`'s `VaultClient.getPoolStats` already return.
/// `lender_shares` is `U256::zero()` whenever no `user` was passed to `get_pool_stats`.
#[derive(Debug, Clone)]
pub struct VaultPoolStats {
    pub total_assets: U256,
    pub total_reserves: U256,
    pub protocol_reserves: U256,
    pub total_debt_principal: U256,
    pub borrow_cap: U256,
    pub reserve_factor_bps: U256,
    pub total_lender_shares: U256,
    pub lender_shares: U256,
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

    /// The severity-scaled liquidation bonus (bps) `user`'s position would pay a liquidator
    /// right now — see `QieForgeVault.liquidationBonusBpsFor`. Returns the flat base bonus for
    /// a healthy/debt-free position, matching the contract's own non-reverting behavior on that path.
    pub async fn get_liquidation_bonus_bps(&self, user: &str) -> Result<U256, QieForgeError> {
        let user = Address::from_str(user).map_err(|_| QieForgeError::InvalidAddress(user.to_string()))?;
        self.contract()
            .liquidation_bonus_bps_for(user)
            .call()
            .await
            .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))
    }

    /// This lender's own share balance. Zero for any address that has never supplied, or whose
    /// shares were retired by a full bad-debt-wipeout epoch bump — the contract's own getter
    /// already encodes that, this just exposes it.
    pub async fn get_lender_shares(&self, user: &str) -> Result<U256, QieForgeError> {
        let user = Address::from_str(user).map_err(|_| QieForgeError::InvalidAddress(user.to_string()))?;
        self.contract().lender_shares(user).call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))
    }

    /// Pool-level lending stats, independent of any one borrower's own position — the same
    /// real on-chain reads apps/web's `/api/vault-position` route and `@qie-forge/core`'s
    /// `getPoolStats` already expose. Pass `user` to also get that lender's own share balance;
    /// pass `None` to get pool-wide stats only.
    pub async fn get_pool_stats(&self, user: Option<&str>) -> Result<VaultPoolStats, QieForgeError> {
        let contract = self.contract();
        let lender_shares = match user {
            Some(user) => self.get_lender_shares(user).await?,
            None => U256::zero(),
        };
        let total_assets = contract.total_assets().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let total_reserves = contract.total_reserves().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let protocol_reserves =
            contract.protocol_reserves().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let total_debt_principal =
            contract.total_debt_principal().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let borrow_cap = contract.borrow_cap().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let reserve_factor_bps =
            contract.reserve_factor_bps().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
        let total_lender_shares =
            contract.total_lender_shares().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;

        Ok(VaultPoolStats {
            total_assets,
            total_reserves,
            protocol_reserves,
            total_debt_principal,
            borrow_cap,
            reserve_factor_bps,
            total_lender_shares,
            lender_shares,
        })
    }
}
