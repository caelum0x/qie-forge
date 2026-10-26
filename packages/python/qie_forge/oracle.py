"""QIE Oracle client — mirrors packages/core/src/oracle.ts exactly,
including the real, independently-verified ABI correction: QIE's own docs
describe `getPrice(string) view returns (uint256)`, which reverts on the
real deployed contracts. The real deployed bytecode is a Chainlink
AggregatorV3Interface clone (confirmed live via eth_call on 2026-10-26 —
decimals()=8, description()="BTC / USDT", latestRoundData() returning a
real round). This client uses the REAL interface.
"""

from __future__ import annotations

from dataclasses import dataclass

from .chain import ChainClient
from .errors import QieForgeError

QIE_ORACLE_ABI: list[dict] = [
    {
        "type": "function",
        "name": "decimals",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint8"}],
    },
    {
        "type": "function",
        "name": "description",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "string"}],
    },
    {
        "type": "function",
        "name": "latestRoundData",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [
            {"name": "roundId", "type": "uint80"},
            {"name": "answer", "type": "int256"},
            {"name": "startedAt", "type": "uint256"},
            {"name": "updatedAt", "type": "uint256"},
            {"name": "answeredInRound", "type": "uint80"},
        ],
    },
]

# Published at docs.qie.digital/qie-oracle/deployed-contracts, confirmed
# live via eth_getCode + a real latestRoundData() call on Mainnet only.
QIE_ORACLE_ADDRESSES: dict[str, str] = {
    "BTC": "0x9E596d809a20A272c788726f592c0d1629755440",
    "ETH": "0x4bb7012Fbc79fE4Ae9B664228977b442b385500d",
    "XRP": "0x804582B1f8Fea73919e7c737115009f668f97528",
    "SOL": "0xe86999c8e6C8eeF71bebd35286bCa674E0AD7b21",
    "QIE": "0x3Bc617cF3A4Bb77003e4c556B87b13D556903D17",
    "XAUt": "0x9aD0199a67588ee293187d26bA1BE61cb07A214c",
    "BNB": "0x775A56117Fdb8b31877E75Ceeb68C96765b031e6",
}


@dataclass
class QieOraclePriceResult:
    asset: str
    network: str
    contract_address: str
    description: str
    decimals: int
    round_id: int
    answer: int
    updated_at: int

    @property
    def human_price(self) -> float:
        return self.answer / (10**self.decimals)


class OracleClient:
    def __init__(self, chain: ChainClient, deployed_networks: list[str] | None = None):
        self._chain = chain
        self._deployed_networks = set(deployed_networks or ["mainnet"])

    def list_supported_assets(self) -> list[str]:
        return list(QIE_ORACLE_ADDRESSES.keys())

    def get_contract_address(self, asset: str) -> str:
        address = QIE_ORACLE_ADDRESSES.get(asset)
        if not address:
            raise QieForgeError(
                "ORACLE_ASSET_UNSUPPORTED",
                f'"{asset}" has no known QIE Oracle contract. Supported: {", ".join(self.list_supported_assets())}',
                {"asset": asset},
            )
        return address

    def get_price(self, asset: str) -> QieOraclePriceResult:
        address = self.get_contract_address(asset)
        network = self._chain.config.name

        if network not in self._deployed_networks:
            raise QieForgeError(
                "ORACLE_NOT_DEPLOYED",
                f'QIE Oracle for "{asset}" is not configured as deployed on "{network}" '
                f"(allowlist is {sorted(self._deployed_networks)}). Verified live 2026-10-26: real "
                f"bytecode on Mainnet (1990), empty bytecode on Testnet (1983) at the same address.",
                {"asset": asset, "network": network, "address": address},
            )

        if not self._chain.is_contract_deployed(address):
            raise QieForgeError(
                "ORACLE_NOT_DEPLOYED",
                f"eth_getCode returned no bytecode for the {asset} oracle at {address} on {network}.",
                {"asset": asset, "network": network, "address": address},
            )

        decimals = self._chain.read_contract(address, QIE_ORACLE_ABI, "decimals")
        description = self._chain.read_contract(address, QIE_ORACLE_ABI, "description")
        round_id, answer, _started_at, updated_at, _answered_in_round = self._chain.read_contract(
            address, QIE_ORACLE_ABI, "latestRoundData"
        )

        if answer <= 0:
            raise QieForgeError(
                "INVALID_RESPONSE",
                f"QIE Oracle for {asset} returned a non-positive answer ({answer}).",
                {"asset": asset, "network": network, "address": address},
            )

        return QieOraclePriceResult(
            asset=asset,
            network=network,
            contract_address=address,
            description=description,
            decimals=decimals,
            round_id=round_id,
            answer=answer,
            updated_at=updated_at,
        )

    def get_prices(self, assets: list[str]) -> list[QieOraclePriceResult]:
        return [self.get_price(asset) for asset in assets]
