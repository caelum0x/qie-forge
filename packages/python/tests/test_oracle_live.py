import os

import pytest

from qie_forge.chain import ChainClient
from qie_forge.errors import QieForgeError
from qie_forge.oracle import OracleClient

LIVE = os.environ.get("QIE_FORGE_RUN_LIVE_TESTS") == "1"
pytestmark = pytest.mark.skipif(not LIVE, reason="set QIE_FORGE_RUN_LIVE_TESTS=1 to run against the real chain")


def test_mainnet_btc_price_is_real_and_positive():
    chain = ChainClient("mainnet")
    oracle = OracleClient(chain, deployed_networks=["mainnet"])
    result = oracle.get_price("BTC")
    assert result.answer > 0
    assert result.decimals == 8
    assert "BTC" in result.description.upper()


def test_mainnet_qie_price_is_real_and_positive():
    chain = ChainClient("mainnet")
    oracle = OracleClient(chain, deployed_networks=["mainnet"])
    result = oracle.get_price("QIE")
    assert result.answer > 0


def test_testnet_fails_closed_instead_of_guessing():
    chain = ChainClient("testnet")
    oracle = OracleClient(chain, deployed_networks=["testnet"])
    with pytest.raises(QieForgeError) as exc_info:
        oracle.get_price("BTC")
    assert exc_info.value.code == "ORACLE_NOT_DEPLOYED"


def test_unsupported_asset_rejected_before_network_call():
    chain = ChainClient("mainnet")
    oracle = OracleClient(chain)
    with pytest.raises(QieForgeError) as exc_info:
        oracle.get_price("DOGE")
    assert exc_info.value.code == "ORACLE_ASSET_UNSUPPORTED"
