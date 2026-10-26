"""Pure constant-product routing math + swap-transaction building — mirrors
packages/contracts/src/libraries/QieForgeLibrary.sol and
packages/contracts/src/QieForgeRouter.sol exactly (same 30bps fee, same
formulas), so a Python caller gets the identical quote a real
QieForgeRouter.getAmountsOut/getAmountsIn call would return, and can build
the matching on-chain transaction without needing the TypeScript SDK.
"""

from __future__ import annotations

from .chain import ChainClient
from .errors import QieForgeError

FEE_BPS = 30
BPS_DENOMINATOR = 10_000

ROUTER_ABI: list[dict] = [
    {
        "type": "function",
        "name": "swapExactTokensForTokens",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "amountIn", "type": "uint256"},
            {"name": "amountOutMin", "type": "uint256"},
            {"name": "path", "type": "address[]"},
            {"name": "to", "type": "address"},
            {"name": "deadline", "type": "uint256"},
        ],
        "outputs": [{"name": "amounts", "type": "uint256[]"}],
    },
    {
        "type": "function",
        "name": "getAmountsOut",
        "stateMutability": "view",
        "inputs": [{"name": "amountIn", "type": "uint256"}, {"name": "path", "type": "address[]"}],
        "outputs": [{"name": "", "type": "uint256[]"}],
    },
]

FACTORY_ABI: list[dict] = [
    {
        "type": "function",
        "name": "getPair",
        "stateMutability": "view",
        "inputs": [{"name": "tokenA", "type": "address"}, {"name": "tokenB", "type": "address"}],
        "outputs": [{"name": "pair", "type": "address"}],
    },
]

PAIR_ABI: list[dict] = [
    {
        "type": "function",
        "name": "getReserves",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [
            {"name": "reserve0", "type": "uint112"},
            {"name": "reserve1", "type": "uint112"},
            {"name": "blockTimestampLast", "type": "uint32"},
        ],
    },
    {"type": "function", "name": "token0", "stateMutability": "view", "inputs": [], "outputs": [{"type": "address"}]},
]


class AmmQuoteError(QieForgeError):
    pass


def get_amount_out(amount_in: int, reserve_in: int, reserve_out: int) -> int:
    if amount_in <= 0:
        raise AmmQuoteError("INVALID_RESPONSE", "amountIn must be positive")
    if reserve_in <= 0 or reserve_out <= 0:
        raise AmmQuoteError("INVALID_RESPONSE", "reserves must be positive")
    amount_in_with_fee = amount_in * (BPS_DENOMINATOR - FEE_BPS)
    numerator = amount_in_with_fee * reserve_out
    denominator = reserve_in * BPS_DENOMINATOR + amount_in_with_fee
    return numerator // denominator


def get_amount_in(amount_out: int, reserve_in: int, reserve_out: int) -> int:
    if amount_out <= 0:
        raise AmmQuoteError("INVALID_RESPONSE", "amountOut must be positive")
    if reserve_in <= 0 or reserve_out <= amount_out:
        raise AmmQuoteError("INVALID_RESPONSE", "insufficient liquidity for requested amountOut")
    numerator = reserve_in * amount_out * BPS_DENOMINATOR
    denominator = (reserve_out - amount_out) * (BPS_DENOMINATOR - FEE_BPS)
    return numerator // denominator + 1


def quote(amount_a: int, reserve_a: int, reserve_b: int) -> int:
    if amount_a <= 0:
        raise AmmQuoteError("INVALID_RESPONSE", "amountA must be positive")
    if reserve_a <= 0 or reserve_b <= 0:
        raise AmmQuoteError("INVALID_RESPONSE", "reserves must be positive")
    return (amount_a * reserve_b) // reserve_a


def get_reserves(chain: ChainClient, factory_address: str, token_a: str, token_b: str) -> tuple[int, int]:
    pair = chain.read_contract(factory_address, FACTORY_ABI, "getPair", [token_a, token_b])
    if int(pair, 16) == 0:
        raise AmmQuoteError("INVALID_RESPONSE", f"No pair deployed for {token_a}/{token_b} on {factory_address}")
    reserve0, reserve1, _ts = chain.read_contract(pair, PAIR_ABI, "getReserves")
    token0 = chain.read_contract(pair, PAIR_ABI, "token0")
    return (reserve0, reserve1) if token_a.lower() == token0.lower() else (reserve1, reserve0)


def get_amounts_out(chain: ChainClient, factory_address: str, amount_in: int, path: list[str]) -> list[int]:
    if len(path) < 2:
        raise AmmQuoteError("INVALID_RESPONSE", "path must have at least 2 tokens")
    amounts = [amount_in]
    for i in range(len(path) - 1):
        reserve_in, reserve_out = get_reserves(chain, factory_address, path[i], path[i + 1])
        amounts.append(get_amount_out(amounts[-1], reserve_in, reserve_out))
    return amounts


def build_swap_exact_tokens_for_tokens_tx(
    chain: ChainClient,
    router_address: str,
    amount_in: int,
    amount_out_min: int,
    path: list[str],
    to: str,
    deadline: int,
    from_address: str,
) -> dict:
    """Builds an UNSIGNED transaction dict for swapExactTokensForTokens.
    Never signs or broadcasts — the caller (or a real wallet) is
    responsible for that. This exists so a Python integration doesn't need
    the TypeScript SDK to prepare a real on-chain call."""
    contract = chain.w3.eth.contract(address=chain.w3.to_checksum_address(router_address), abi=ROUTER_ABI)
    return contract.functions.swapExactTokensForTokens(
        amount_in, amount_out_min, [chain.w3.to_checksum_address(a) for a in path], to, deadline
    ).build_transaction({"from": chain.w3.to_checksum_address(from_address)})
