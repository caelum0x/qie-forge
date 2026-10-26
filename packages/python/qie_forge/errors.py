"""Typed error taxonomy for the QIE Forge Python SDK — mirrors
packages/core/src/errors.ts. Every client fails CLOSED on missing or
unconfirmed configuration rather than guessing a contract address, RPC URL,
or price.
"""

from __future__ import annotations


class QieForgeError(Exception):
    """Base error for all QIE Forge SDK failures."""

    def __init__(self, code: str, message: str, details: dict | None = None):
        super().__init__(message)
        self.code = code
        self.details = details or {}

    def __repr__(self) -> str:  # pragma: no cover - cosmetic
        return f"QieForgeError(code={self.code!r}, message={str(self)!r})"
