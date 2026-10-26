"""Pure math tests — cross-checked by hand against the same 30bps
constant-product formula QieForgeLibrary.sol and QieForgePair.sol implement
on-chain (see packages/contracts/test/QieForgePair.t.sol's equivalent
Solidity assertions for the same numbers)."""

import pytest

from qie_forge.amm import AmmQuoteError, get_amount_in, get_amount_out, quote


def test_get_amount_out_matches_hand_calculation():
    # reserves 10_000/10_000, amountIn=100 -> same numbers used in the
    # Solidity test_swap_respectsConstantProductWithFee test.
    amount_in = 100 * 10**18
    reserve_in = 10_000 * 10**18
    reserve_out = 10_000 * 10**18
    amount_in_with_fee = amount_in * 9970
    expected = (amount_in_with_fee * reserve_out) // (reserve_in * 10_000 + amount_in_with_fee)
    assert get_amount_out(amount_in, reserve_in, reserve_out) == expected
    assert expected < amount_in  # fee + slippage means strictly less than 1:1


def test_get_amount_out_get_amount_in_are_consistent():
    reserve_in, reserve_out = 50_000 * 10**18, 20_000 * 10**18
    amount_in = 1_000 * 10**18
    amount_out = get_amount_out(amount_in, reserve_in, reserve_out)
    # Integer floor division on both legs means the round trip isn't exact —
    # the same characteristic any constant-product-with-fee integer formula
    # has. Recovering the input for that exact output should land within a
    # few wei of the original, never systematically short-changing the pool
    # by more than rounding error.
    recovered_in = get_amount_in(amount_out, reserve_in, reserve_out)
    assert abs(recovered_in - amount_in) <= 2


def test_quote_is_proportional():
    assert quote(100, 1000, 4000) == 400


def test_rejects_non_positive_inputs():
    with pytest.raises(AmmQuoteError):
        get_amount_out(0, 1000, 1000)
    with pytest.raises(AmmQuoteError):
        get_amount_in(1000, 1000, 500)  # amountOut >= reserveOut
    with pytest.raises(AmmQuoteError):
        quote(0, 1000, 1000)
