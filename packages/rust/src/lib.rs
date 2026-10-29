//! QIE Forge Rust SDK — mirrors `@qie-forge/core` (TypeScript) and
//! `qie_forge` (Python): a real chain client, the real (corrected) QIE
//! Oracle ABI, a fail-closed QUSDC helper, and pure AMM quote math.

pub mod amm;
pub mod chain;
pub mod errors;
pub mod networks;
pub mod oracle;
pub mod qusdc;
pub mod vault;

pub use amm::{build_swap_exact_tokens_for_tokens_tx, get_amounts_out_onchain, get_reserves};
pub use chain::{ChainClient, ChainSnapshot};
pub use errors::QieForgeError;
pub use networks::{resolve_network, QieNetwork, QieNetworkConfig};
pub use oracle::{oracle_addresses, OracleClient, OraclePriceResult};
pub use qusdc::{resolve_qusdc_config, QusdcConfig};
pub use vault::{VaultClient, VaultPoolStats, VaultPosition};
