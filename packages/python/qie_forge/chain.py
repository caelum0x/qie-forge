"""Typed wrapper around QIE's EVM JSON-RPC surface — mirrors
packages/core/src/chain.ts. QIE exposes standard eth_* methods, so this
reuses web3.py rather than hand-rolling JSON-RPC framing.
"""

from __future__ import annotations

from dataclasses import dataclass

from web3 import Web3
from web3.exceptions import Web3RPCError

from .errors import QieForgeError
from .networks import QieNetworkConfig, resolve_network


@dataclass
class ChainSnapshot:
    network: str
    chain_id: int
    block_number: int
    block_hash: str
    timestamp: int
    gas_price: int


class ChainClient:
    def __init__(
        self,
        network: str | None = None,
        rpc_url: str | None = None,
        timeout: float = 10.0,
        config: QieNetworkConfig | None = None,
    ):
        """Either pass `network` ("testnet"/"mainnet", optionally with an
        `rpc_url` override), or pass a fully custom `config` directly —
        e.g. for a local anvil devnet used in integration tests, which is
        not one of QIE's real networks and has no business pretending to
        be "testnet"."""
        if config is not None:
            self.config = config
        elif network is not None:
            self.config = resolve_network(network, rpc_url)
        else:
            raise QieForgeError("UNSUPPORTED_NETWORK", "Either `network` or `config` must be provided")
        self._w3 = Web3(Web3.HTTPProvider(self.config.rpc_url, request_kwargs={"timeout": timeout}))

    def verify_chain_id(self) -> int:
        try:
            chain_id = self._w3.eth.chain_id
        except Exception as exc:  # noqa: BLE001 - normalize every transport failure
            raise QieForgeError(
                "NETWORK_UNREACHABLE",
                f"Could not reach QIE {self.config.name} RPC at {self.config.rpc_url}: {exc}",
                {"rpc_url": self.config.rpc_url},
            ) from exc

        if chain_id != self.config.chain_id:
            raise QieForgeError(
                "INVALID_RESPONSE",
                f"RPC at {self.config.rpc_url} returned chain ID {chain_id}, expected "
                f"{self.config.chain_id} ({self.config.name}). Refusing to proceed on a mismatched network.",
                {"expected": self.config.chain_id, "actual": chain_id},
            )
        return chain_id

    def get_snapshot(self) -> ChainSnapshot:
        chain_id = self.verify_chain_id()
        block = self._w3.eth.get_block("latest")
        gas_price = self._w3.eth.gas_price
        return ChainSnapshot(
            network=self.config.name,
            chain_id=chain_id,
            block_number=block["number"],
            block_hash=block["hash"].hex(),
            timestamp=block["timestamp"],
            gas_price=gas_price,
        )

    def get_balance(self, address: str) -> int:
        self._assert_address(address)
        return self._w3.eth.get_balance(Web3.to_checksum_address(address))

    def get_code(self, address: str) -> bytes:
        self._assert_address(address)
        return self._w3.eth.get_code(Web3.to_checksum_address(address))

    def is_contract_deployed(self, address: str) -> bool:
        code = self.get_code(address)
        return len(code) > 0

    def read_contract(self, address: str, abi: list[dict], function_name: str, args: list | None = None):
        self._assert_address(address)
        contract = self._w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)
        fn = getattr(contract.functions, function_name)
        try:
            return fn(*(args or [])).call()
        except Web3RPCError as exc:
            raise QieForgeError(
                "INVALID_RESPONSE",
                f"eth_call to {function_name} at {address} reverted: {exc}",
                {"address": address, "function": function_name},
            ) from exc

    @property
    def w3(self) -> Web3:
        return self._w3

    def _assert_address(self, address: str) -> None:
        if not Web3.is_address(address):
            raise QieForgeError("INVALID_ADDRESS", f'"{address}" is not a valid EVM address', {"address": address})
