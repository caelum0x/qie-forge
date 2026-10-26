//! Typed error taxonomy — mirrors packages/core/src/errors.ts and
//! packages/python/qie_forge/errors.py. Every client fails CLOSED on
//! missing/unconfirmed configuration rather than guessing.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum QieForgeError {
    #[error("network unreachable: {0}")]
    NetworkUnreachable(String),

    #[error("unsupported network: {0}")]
    UnsupportedNetwork(String),

    #[error("QIE Oracle not deployed: {0}")]
    OracleNotDeployed(String),

    #[error("QIE Oracle asset unsupported: {0}")]
    OracleAssetUnsupported(String),

    #[error("asset not configured: {0}")]
    AssetNotConfigured(String),

    #[error("invalid address: {0}")]
    InvalidAddress(String),

    #[error("invalid response: {0}")]
    InvalidResponse(String),
}
