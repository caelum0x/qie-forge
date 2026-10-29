"""Read-only client for a deployed QieForgeVault — mirrors the vault's real
ABI (packages/contracts/src/vault/QieForgeVault.sol). No write/borrow/repay
methods are included here deliberately: this SDK builds unsigned
transactions (see amm.py's pattern) rather than ever holding or using a
private key itself.
"""

from __future__ import annotations

from dataclasses import dataclass

from .chain import ChainClient

VAULT_ABI: list[dict] = [
    {
        "type": "function",
        "name": "positions",
        "stateMutability": "view",
        "inputs": [{"name": "", "type": "address"}],
        "outputs": [
            {"name": "collateral", "type": "uint128"},
            {"name": "debtPrincipal", "type": "uint128"},
            {"name": "lastAccrual", "type": "uint64"},
        ],
    },
    {
        "type": "function",
        "name": "healthFactor",
        "stateMutability": "view",
        "inputs": [{"name": "user", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "currentDebt",
        "stateMutability": "view",
        "inputs": [{"name": "user", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "ltvBps",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "liquidationThresholdBps",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "liquidationBonusBpsFor",
        "stateMutability": "view",
        "inputs": [{"name": "user", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "totalAssets",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "totalReserves",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "protocolReserves",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "totalDebtPrincipal",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "borrowCap",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "reserveFactorBps",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "totalLenderShares",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "lenderShares",
        "stateMutability": "view",
        "inputs": [{"name": "user", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
]

WAD = 10**18


@dataclass
class VaultPosition:
    collateral: int
    debt_principal: int
    last_accrual: int
    health_factor: int
    current_debt: int

    @property
    def is_liquidatable(self) -> bool:
        return self.debt_principal > 0 and self.health_factor < WAD


@dataclass
class VaultPoolStats:
    """Lending-pool-level stats, independent of any one borrower's own
    position — field-for-field the same shape apps/web/app/api/
    vault-position/route.ts and @qie-forge/core's `VaultClient.getPoolStats`
    already return. `lender_shares` is 0 whenever no `user` was passed."""

    total_assets: int
    total_reserves: int
    protocol_reserves: int
    total_debt_principal: int
    borrow_cap: int
    reserve_factor_bps: int
    total_lender_shares: int
    lender_shares: int


class VaultClient:
    def __init__(self, chain: ChainClient, vault_address: str):
        self._chain = chain
        self.vault_address = vault_address

    def get_position(self, user: str) -> VaultPosition:
        collateral, debt_principal, last_accrual = self._chain.read_contract(
            self.vault_address, VAULT_ABI, "positions", [user]
        )
        health_factor = self._chain.read_contract(self.vault_address, VAULT_ABI, "healthFactor", [user])
        current_debt = self._chain.read_contract(self.vault_address, VAULT_ABI, "currentDebt", [user])
        return VaultPosition(
            collateral=collateral,
            debt_principal=debt_principal,
            last_accrual=last_accrual,
            health_factor=health_factor,
            current_debt=current_debt,
        )

    def get_ltv_bps(self) -> int:
        return self._chain.read_contract(self.vault_address, VAULT_ABI, "ltvBps")

    def get_liquidation_threshold_bps(self) -> int:
        return self._chain.read_contract(self.vault_address, VAULT_ABI, "liquidationThresholdBps")

    def get_liquidation_bonus_bps(self, user: str) -> int:
        """The severity-scaled liquidation bonus (bps) `user`'s position
        would pay a liquidator right now — see
        `QieForgeVault.liquidationBonusBpsFor`. Returns the flat base bonus
        for a healthy/debt-free position, matching the contract's own
        non-reverting behavior on that path."""
        return self._chain.read_contract(self.vault_address, VAULT_ABI, "liquidationBonusBpsFor", [user])

    def get_lender_shares(self, user: str) -> int:
        """This lender's own share balance. 0 for any address that has
        never supplied, or whose shares were retired by a full
        bad-debt-wipeout epoch bump — the contract's own getter already
        encodes that, this just exposes it."""
        return self._chain.read_contract(self.vault_address, VAULT_ABI, "lenderShares", [user])

    def get_pool_stats(self, user: str | None = None) -> VaultPoolStats:
        """Pool-level lending stats, independent of any one borrower's own
        position — the same real on-chain reads apps/web's
        `/api/vault-position` route and @qie-forge/core's `getPoolStats`
        already expose. Pass `user` to also get that lender's own share
        balance; omit it to get pool-wide stats only."""
        lender_shares = 0 if user is None else self.get_lender_shares(user)
        return VaultPoolStats(
            total_assets=self._chain.read_contract(self.vault_address, VAULT_ABI, "totalAssets"),
            total_reserves=self._chain.read_contract(self.vault_address, VAULT_ABI, "totalReserves"),
            protocol_reserves=self._chain.read_contract(self.vault_address, VAULT_ABI, "protocolReserves"),
            total_debt_principal=self._chain.read_contract(self.vault_address, VAULT_ABI, "totalDebtPrincipal"),
            borrow_cap=self._chain.read_contract(self.vault_address, VAULT_ABI, "borrowCap"),
            reserve_factor_bps=self._chain.read_contract(self.vault_address, VAULT_ABI, "reserveFactorBps"),
            total_lender_shares=self._chain.read_contract(self.vault_address, VAULT_ABI, "totalLenderShares"),
            lender_shares=lender_shares,
        )
