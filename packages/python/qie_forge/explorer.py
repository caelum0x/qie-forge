"""Blockscout REST API client — mirrors packages/core/src/explorer.ts.
QIE already runs a real Blockscout-family explorer; this does not
re-implement indexing, only wraps the existing public API.
"""

from __future__ import annotations

from dataclasses import dataclass

import requests

from .errors import QieForgeError
from .networks import QieNetworkConfig


@dataclass
class ExplorerAddressInfo:
    hash: str
    is_contract: bool
    is_verified: bool | None
    coin_balance: str | None


class ExplorerClient:
    def __init__(self, network: QieNetworkConfig, timeout: float = 10.0):
        self._network = network
        self._timeout = timeout

    def _fetch_json(self, path: str) -> dict:
        url = f"{self._network.explorer_api_url}{path}"
        try:
            res = requests.get(url, timeout=self._timeout)
        except requests.RequestException as exc:
            raise QieForgeError(
                "EXPLORER_UNAVAILABLE",
                f"Could not reach QIE {self._network.name} explorer API at {url}: {exc}",
                {"url": url},
            ) from exc
        if not res.ok:
            raise QieForgeError(
                "EXPLORER_UNAVAILABLE",
                f"QIE {self._network.name} explorer API returned HTTP {res.status_code} for {url}",
                {"url": url, "status": res.status_code},
            )
        return res.json()

    def get_address(self, address: str) -> ExplorerAddressInfo:
        data = self._fetch_json(f"/v2/addresses/{address}")
        return ExplorerAddressInfo(
            hash=str(data.get("hash", address)),
            is_contract=bool(data.get("is_contract")),
            is_verified=data.get("is_verified"),
            coin_balance=data.get("coin_balance"),
        )

    def address_url(self, address: str) -> str:
        return f"{self._network.explorer_url}/address/{address}"

    def tx_url(self, tx_hash: str) -> str:
        return f"{self._network.explorer_url}/tx/{tx_hash}"
