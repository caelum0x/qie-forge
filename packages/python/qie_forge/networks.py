"""Network configs — mirrors packages/core/src/networks.ts exactly, same
verified endpoints and the same override-via-env posture (hosted RPC URLs on
this chain have already moved once; never hardcode trust in one endpoint
without an override path).
"""

from __future__ import annotations

import os
from dataclasses import dataclass, replace

from .errors import QieForgeError


@dataclass(frozen=True)
class QieNetworkConfig:
    name: str
    chain_id: int
    rpc_url: str
    explorer_url: str
    explorer_api_url: str
    native_currency_symbol: str = "QIE"


_NETWORKS: dict[str, QieNetworkConfig] = {
    "testnet": QieNetworkConfig(
        name="testnet",
        chain_id=1983,
        rpc_url="https://testnet.qie.digital/api/eth-rpc",
        explorer_url="https://testnet.qie.digital",
        explorer_api_url="https://testnet.qie.digital/api",
    ),
    "mainnet": QieNetworkConfig(
        name="mainnet",
        chain_id=1990,
        rpc_url="https://rpc1mainnet.qie.digital",
        explorer_url="https://mainnet.qie.digital",
        explorer_api_url="https://mainnet.qie.digital/api",
    ),
}


def resolve_network(name: str, rpc_url: str | None = None) -> QieNetworkConfig:
    base = _NETWORKS.get(name)
    if base is None:
        raise QieForgeError(
            "UNSUPPORTED_NETWORK",
            f'Unsupported QIE network "{name}". Supported: {", ".join(_NETWORKS)}',
        )

    env_var = "QIE_FORGE_TESTNET_RPC_URL" if name == "testnet" else "QIE_FORGE_MAINNET_RPC_URL"
    resolved_rpc = rpc_url or os.environ.get(env_var) or base.rpc_url
    return replace(base, rpc_url=resolved_rpc)


def list_networks() -> list[QieNetworkConfig]:
    return list(_NETWORKS.values())
