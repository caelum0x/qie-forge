import os

import pytest

from qie_forge.errors import QieForgeError
from qie_forge.networks import list_networks, resolve_network


@pytest.fixture(autouse=True)
def _clear_env():
    for key in ("QIE_FORGE_TESTNET_RPC_URL", "QIE_FORGE_MAINNET_RPC_URL"):
        os.environ.pop(key, None)
    yield
    for key in ("QIE_FORGE_TESTNET_RPC_URL", "QIE_FORGE_MAINNET_RPC_URL"):
        os.environ.pop(key, None)


def test_lists_testnet_and_mainnet():
    nets = {n.name: n for n in list_networks()}
    assert nets["testnet"].chain_id == 1983
    assert nets["mainnet"].chain_id == 1990


def test_default_rpc_urls():
    assert resolve_network("testnet").rpc_url == "https://testnet.qie.digital/api/eth-rpc"
    assert resolve_network("mainnet").rpc_url == "https://rpc1mainnet.qie.digital"


def test_explicit_override_wins_over_env():
    os.environ["QIE_FORGE_TESTNET_RPC_URL"] = "https://env.example/"
    resolved = resolve_network("testnet", rpc_url="https://explicit.example/")
    assert resolved.rpc_url == "https://explicit.example/"


def test_env_override_used_when_no_explicit_value():
    os.environ["QIE_FORGE_MAINNET_RPC_URL"] = "https://env-mainnet.example/"
    assert resolve_network("mainnet").rpc_url == "https://env-mainnet.example/"


def test_unsupported_network_raises():
    with pytest.raises(QieForgeError) as exc_info:
        resolve_network("devnet")
    assert exc_info.value.code == "UNSUPPORTED_NETWORK"
