"""QUSDC fail-closed asset helper — mirrors packages/core/src/qusdc.ts.
QUSDC's ERC-20 contract address was NOT independently confirmed by this
project's research (same conclusion the TypeScript SDK and cred402's prior
QIE research both reached). No default is ever guessed.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from .chain import ChainClient
from .errors import QieForgeError

_ERC20_ABI: list[dict] = [
    {
        "type": "function",
        "name": "balanceOf",
        "stateMutability": "view",
        "inputs": [{"name": "account", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "totalSupply",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
    },
]


@dataclass
class QusdcConfig:
    address: str
    decimals: int


def resolve_qusdc_config(address: str | None = None, decimals: int | None = None) -> QusdcConfig:
    resolved_address = address or os.environ.get("QIE_FORGE_QUSDC_ADDRESS")
    if not resolved_address:
        raise QieForgeError(
            "ASSET_NOT_CONFIGURED",
            "QUSDC's ERC-20 contract address is not independently confirmed by QIE Forge's own "
            "research. Set QIE_FORGE_QUSDC_ADDRESS (and optionally QIE_FORGE_QUSDC_DECIMALS, "
            "default 6) to enable QusdcClient. QIE Forge never guesses this value.",
        )

    raw_decimals = decimals if decimals is not None else os.environ.get("QIE_FORGE_QUSDC_DECIMALS")
    resolved_decimals = 6 if raw_decimals is None else int(raw_decimals)
    if resolved_decimals < 0 or resolved_decimals > 36:
        raise QieForgeError(
            "ASSET_NOT_CONFIGURED", f"QIE_FORGE_QUSDC_DECIMALS must be a small non-negative integer, got {raw_decimals!r}."
        )

    return QusdcConfig(address=resolved_address, decimals=resolved_decimals)


class QusdcClient:
    def __init__(self, chain: ChainClient, address: str | None = None, decimals: int | None = None):
        self._chain = chain
        self.config = resolve_qusdc_config(address, decimals)

    def verify_deployed(self) -> bool:
        return self._chain.is_contract_deployed(self.config.address)

    def balance_of(self, holder: str) -> int:
        return self._chain.read_contract(self.config.address, _ERC20_ABI, "balanceOf", [holder])

    def total_supply(self) -> int:
        return self._chain.read_contract(self.config.address, _ERC20_ABI, "totalSupply")
