import os

import pytest

from qie_forge.errors import QieForgeError
from qie_forge.qusdc import resolve_qusdc_config


@pytest.fixture(autouse=True)
def _clear_env():
    for key in ("QIE_FORGE_QUSDC_ADDRESS", "QIE_FORGE_QUSDC_DECIMALS"):
        os.environ.pop(key, None)
    yield
    for key in ("QIE_FORGE_QUSDC_ADDRESS", "QIE_FORGE_QUSDC_DECIMALS"):
        os.environ.pop(key, None)


def test_raises_when_unconfigured():
    with pytest.raises(QieForgeError) as exc_info:
        resolve_qusdc_config()
    assert exc_info.value.code == "ASSET_NOT_CONFIGURED"


def test_explicit_address_accepted_with_default_decimals():
    cfg = resolve_qusdc_config(address="0x1111111111111111111111111111111111111111")
    assert cfg.address == "0x1111111111111111111111111111111111111111"
    assert cfg.decimals == 6


def test_env_var_address_and_decimals():
    os.environ["QIE_FORGE_QUSDC_ADDRESS"] = "0x2222222222222222222222222222222222222222"
    os.environ["QIE_FORGE_QUSDC_DECIMALS"] = "18"
    cfg = resolve_qusdc_config()
    assert cfg.decimals == 18


def test_invalid_decimals_rejected():
    os.environ["QIE_FORGE_QUSDC_ADDRESS"] = "0x2222222222222222222222222222222222222222"
    with pytest.raises(QieForgeError):
        resolve_qusdc_config(decimals=999)
