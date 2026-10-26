# qie-forge (Python SDK)

Python client mirroring `@qie-forge/core`: a real chain client (web3.py),
the real (corrected) QIE Oracle ABI, a fail-closed QUSDC helper, a
Blockscout explorer client, pure AMM quote math + unsigned-transaction
building, and a read-only lending-vault client.

## Install

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

## Usage

```python
from qie_forge import ChainClient, OracleClient

chain = ChainClient("mainnet")
print(chain.get_snapshot())

oracle = OracleClient(chain, deployed_networks=["mainnet"])
btc = oracle.get_price("BTC")
print(btc.asset, btc.human_price, btc.description)
```

## Tests

```bash
pytest -q                                  # unit + anvil-integration tests (offline-safe, no live network)
QIE_FORGE_RUN_LIVE_TESTS=1 pytest -q       # also hits the real QIE testnet/mainnet RPCs
```

- `tests/test_networks.py`, `tests/test_qusdc.py`, `tests/test_amm_math.py` — pure unit tests, no network.
- `tests/test_chain_live.py`, `tests/test_oracle_live.py` — real calls against `https://testnet.qie.digital/api/eth-rpc` (chain 1983) and `https://rpc1mainnet.qie.digital` (chain 1990), gated behind `QIE_FORGE_RUN_LIVE_TESTS=1`.
- `tests/test_anvil_integration.py` — deploys the ACTUAL compiled `packages/contracts` bytecode to a local `anvil` devnet and exercises `VaultClient`/`amm.py` against it; requires Foundry's `anvil` on `PATH` (skips cleanly if absent).

23/23 tests pass as of 2026-10-26 (15 offline-safe + 8 live).
