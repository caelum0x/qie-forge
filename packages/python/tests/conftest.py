"""Session-scoped local anvil devnet for integration tests that need a
REAL EVM to deploy the actual compiled QIE Forge contracts against — not a
substitute for the live testnet/mainnet tests (which hit the real chain),
but a way to prove the Python SDK's read/write-building logic against real
bytecode without needing a funded deployer key on the live network."""

from __future__ import annotations

import shutil
import socket
import subprocess
import time

import pytest
from web3 import Web3

ANVIL_PORT = 8646


def _port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


@pytest.fixture(scope="session")
def anvil_rpc_url():
    if shutil.which("anvil") is None:
        pytest.skip("anvil (Foundry) is not installed; skipping local-devnet integration tests")

    proc = subprocess.Popen(
        ["anvil", "--port", str(ANVIL_PORT), "--silent"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(50):
            if _port_open(ANVIL_PORT):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("anvil did not start listening in time")

        url = f"http://127.0.0.1:{ANVIL_PORT}"
        w3 = Web3(Web3.HTTPProvider(url))
        for _ in range(50):
            try:
                w3.eth.block_number
                break
            except Exception:
                time.sleep(0.1)
        yield url
    finally:
        proc.terminate()
        proc.wait(timeout=5)
