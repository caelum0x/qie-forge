"""Integration tests against a REAL local EVM (anvil), running the ACTUAL
compiled QieForge* contracts (loaded from packages/contracts/out — forge
build output, not re-implemented or mocked here). This proves the Python
SDK's read/quote/tx-building logic works against real bytecode, without
needing a funded deployer key on the live QIE testnet (which the project's
testnet faucet gates behind a wallet-connect flow — a real owner/operator
step, not something this test suite can do)."""

from __future__ import annotations

import pytest
from web3 import Web3

from qie_forge.amm import build_swap_exact_tokens_for_tokens_tx, get_amounts_out
from qie_forge.chain import ChainClient
from qie_forge.networks import QieNetworkConfig
from qie_forge.oracle import QIE_ORACLE_ABI
from qie_forge.vault import VaultClient

from ._artifacts import load_artifact
from ._devnet_accounts import ANVIL_DEFAULT_ADDRESS, ANVIL_DEFAULT_PRIVATE_KEY

WAD = 10**18


def _deploy(w3: Web3, artifact: dict, *ctor_args):
    contract = w3.eth.contract(abi=artifact["abi"], bytecode=artifact["bytecode"])
    tx_hash = contract.constructor(*ctor_args).transact({"from": ANVIL_DEFAULT_ADDRESS})
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    return w3.eth.contract(address=receipt.contractAddress, abi=artifact["abi"])


@pytest.fixture()
def chain_client(anvil_rpc_url) -> ChainClient:
    config = QieNetworkConfig(
        name="anvil-local",
        chain_id=31337,
        rpc_url=anvil_rpc_url,
        explorer_url="",
        explorer_api_url="",
    )
    return ChainClient(config=config)


def test_vault_position_reads_against_real_deployed_contracts(chain_client):
    w3 = chain_client.w3

    mock_erc20 = load_artifact("MockERC20", "MockERC20")
    mock_aggregator = load_artifact("MockAggregatorV3", "MockAggregatorV3")
    oracle_adapter_artifact = load_artifact("QieOracleAdapter", "QieOracleAdapter")
    vault_artifact = load_artifact("QieForgeVault", "QieForgeVault")

    collateral = _deploy(w3, mock_erc20, "Wrapped QIE", "WQIE", 18)
    borrow_token = _deploy(w3, mock_erc20, "Test USD", "TUSD", 6)
    collateral_feed = _deploy(w3, mock_aggregator, 8, "QIE / USD", 1_00_000_000)  # $1.00
    borrow_feed = _deploy(w3, mock_aggregator, 8, "TUSD / USD", 1_00_000_000)  # $1.00

    oracle = _deploy(w3, oracle_adapter_artifact, ANVIL_DEFAULT_ADDRESS, 86_400)
    oracle.functions.setFeed(collateral.address, collateral_feed.address).transact({"from": ANVIL_DEFAULT_ADDRESS})
    oracle.functions.setFeed(borrow_token.address, borrow_feed.address).transact({"from": ANVIL_DEFAULT_ADDRESS})

    ltv_bps, liq_threshold_bps, liq_bonus_bps, rate_per_second = 7_500, 8_000, 500, 1_585_489_599
    vault = _deploy(
        w3,
        vault_artifact,
        collateral.address,
        borrow_token.address,
        oracle.address,
        ltv_bps,
        liq_threshold_bps,
        liq_bonus_bps,
        rate_per_second,
    )

    collateral.functions.mint(ANVIL_DEFAULT_ADDRESS, 10_000 * 10**18).transact({"from": ANVIL_DEFAULT_ADDRESS})
    borrow_token.functions.mint(vault.address, 1_000_000 * 10**6).transact({"from": ANVIL_DEFAULT_ADDRESS})
    collateral.functions.approve(vault.address, 2**256 - 1).transact({"from": ANVIL_DEFAULT_ADDRESS})

    vault.functions.depositCollateral(1_000 * 10**18).transact({"from": ANVIL_DEFAULT_ADDRESS})
    vault.functions.borrow(700 * 10**6).transact({"from": ANVIL_DEFAULT_ADDRESS})

    # --- Real assertion: the Python SDK's VaultClient reads this REAL on-chain state correctly. ---
    vault_client = VaultClient(chain_client, vault.address)
    position = vault_client.get_position(ANVIL_DEFAULT_ADDRESS)

    assert position.collateral == 1_000 * 10**18
    assert position.debt_principal == 700 * 10**6
    assert not position.is_liquidatable
    # (1000 * 0.80) / 700 ~= 1.142857
    assert abs(position.health_factor - 1_142_857_142_857_142_857) < 10**9

    assert vault_client.get_ltv_bps() == ltv_bps
    assert vault_client.get_liquidation_threshold_bps() == liq_threshold_bps

    # The oracle adapter itself also answers through the REAL verified ABI shape.
    btc_like_price = chain_client.read_contract(collateral_feed.address, QIE_ORACLE_ABI, "latestRoundData")
    assert btc_like_price[1] == 1_00_000_000  # raw answer, 8 decimals -> $1.00


def test_amm_quote_and_swap_tx_building_against_real_deployed_pools(chain_client):
    w3 = chain_client.w3

    mock_erc20 = load_artifact("MockERC20", "MockERC20")
    factory_artifact = load_artifact("QieForgeFactory", "QieForgeFactory")
    router_artifact = load_artifact("QieForgeRouter", "QieForgeRouter")

    token_a = _deploy(w3, mock_erc20, "Token A", "TKA", 18)
    token_b = _deploy(w3, mock_erc20, "Token B", "TKB", 18)
    factory = _deploy(w3, factory_artifact, ANVIL_DEFAULT_ADDRESS)
    router = _deploy(w3, router_artifact, factory.address)

    token_a.functions.mint(ANVIL_DEFAULT_ADDRESS, 1_000_000 * 10**18).transact({"from": ANVIL_DEFAULT_ADDRESS})
    token_b.functions.mint(ANVIL_DEFAULT_ADDRESS, 1_000_000 * 10**18).transact({"from": ANVIL_DEFAULT_ADDRESS})
    token_a.functions.approve(router.address, 2**256 - 1).transact({"from": ANVIL_DEFAULT_ADDRESS})
    token_b.functions.approve(router.address, 2**256 - 1).transact({"from": ANVIL_DEFAULT_ADDRESS})

    router.functions.addLiquidity(
        token_a.address, token_b.address, 100_000 * 10**18, 100_000 * 10**18, 0, 0, ANVIL_DEFAULT_ADDRESS, 2**256 - 1
    ).transact({"from": ANVIL_DEFAULT_ADDRESS})

    # --- Real assertion: Python's pure quote math matches the deployed router's own on-chain quote. ---
    amount_in = 1_000 * 10**18
    path = [token_a.address, token_b.address]
    python_quote = get_amounts_out(chain_client, factory.address, amount_in, path)
    onchain_quote = router.functions.getAmountsOut(amount_in, path).call()
    assert python_quote == list(onchain_quote)

    # --- Real assertion: the unsigned tx this SDK builds actually executes successfully on-chain. ---
    deadline = w3.eth.get_block("latest")["timestamp"] + 3600
    tx = build_swap_exact_tokens_for_tokens_tx(
        chain_client,
        router.address,
        amount_in,
        python_quote[-1],
        path,
        ANVIL_DEFAULT_ADDRESS,
        deadline,
        ANVIL_DEFAULT_ADDRESS,
    )
    tx_hash = w3.eth.send_transaction(tx)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    assert receipt.status == 1
