"""Hits the REAL QIE testnet and mainnet RPCs. Gated behind
QIE_FORGE_RUN_LIVE_TESTS=1, mirroring packages/core's test:live split, so a
normal `pytest` run stays offline-safe."""

import os

import pytest

from qie_forge.chain import ChainClient

LIVE = os.environ.get("QIE_FORGE_RUN_LIVE_TESTS") == "1"
pytestmark = pytest.mark.skipif(not LIVE, reason="set QIE_FORGE_RUN_LIVE_TESTS=1 to run against the real chain")


def test_testnet_chain_id_and_block_floor():
    client = ChainClient("testnet")
    snapshot = client.get_snapshot()
    assert snapshot.chain_id == 1983
    assert snapshot.block_number > 9_000_000


def test_mainnet_chain_id_and_block_floor():
    client = ChainClient("mainnet")
    snapshot = client.get_snapshot()
    assert snapshot.chain_id == 1990
    assert snapshot.block_number > 11_000_000


def test_random_eoa_has_no_bytecode():
    client = ChainClient("testnet")
    assert client.is_contract_deployed("0x0000000000000000000000000000000000000001") is False


def test_invalid_address_rejected_before_network_call():
    client = ChainClient("testnet")
    with pytest.raises(Exception, match="valid EVM address"):
        client.get_balance("not-an-address")
