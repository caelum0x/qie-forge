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
