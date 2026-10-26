"""Loads real compiled ABI + bytecode from packages/contracts/out (forge
build output) so integration tests deploy and exercise the ACTUAL QIE Forge
contracts on a local anvil devnet — not a re-implementation or a mock of
their behavior."""

from __future__ import annotations

import json
from pathlib import Path

_CONTRACTS_OUT = Path(__file__).resolve().parents[2] / "contracts" / "out"


def load_artifact(solidity_file: str, contract_name: str) -> dict:
    path = _CONTRACTS_OUT / f"{solidity_file}.sol" / f"{contract_name}.json"
    if not path.exists():
        raise FileNotFoundError(
            f"Compiled artifact not found at {path}. Run `forge build` in packages/contracts first."
        )
    with path.open() as f:
        data = json.load(f)
    return {"abi": data["abi"], "bytecode": data["bytecode"]["object"]}
