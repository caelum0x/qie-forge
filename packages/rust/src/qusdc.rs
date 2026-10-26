//! QUSDC fail-closed asset helper — mirrors packages/core/src/qusdc.ts and
//! packages/python/qie_forge/qusdc.py. QUSDC's ERC-20 contract address was
//! NOT independently confirmed by this project's research. No default is
//! ever guessed.

use crate::errors::QieForgeError;

#[derive(Debug, Clone)]
pub struct QusdcConfig {
    pub address: String,
    pub decimals: u8,
}

pub fn resolve_qusdc_config(
    address: Option<String>,
    decimals: Option<u8>,
) -> Result<QusdcConfig, QieForgeError> {
    let resolved_address = address.or_else(|| std::env::var("QIE_FORGE_QUSDC_ADDRESS").ok());
    let Some(resolved_address) = resolved_address else {
        return Err(QieForgeError::AssetNotConfigured(
            "QUSDC's ERC-20 contract address is not independently confirmed by QIE Forge's own \
             research. Set QIE_FORGE_QUSDC_ADDRESS (and optionally QIE_FORGE_QUSDC_DECIMALS, \
             default 6) to enable QUSDC support. QIE Forge never guesses this value."
                .to_string(),
        ));
    };

    let resolved_decimals = match decimals {
        Some(d) => d,
        None => match std::env::var("QIE_FORGE_QUSDC_DECIMALS") {
            Ok(v) => v
                .parse::<u8>()
                .map_err(|_| QieForgeError::AssetNotConfigured(format!("invalid QIE_FORGE_QUSDC_DECIMALS: {v}")))?,
            Err(_) => 6,
        },
    };

    Ok(QusdcConfig { address: resolved_address, decimals: resolved_decimals })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn raises_when_unconfigured() {
        env::remove_var("QIE_FORGE_QUSDC_ADDRESS");
        assert!(resolve_qusdc_config(None, None).is_err());
    }

    #[test]
    fn explicit_address_accepted_with_default_decimals() {
        let cfg = resolve_qusdc_config(Some("0x1111111111111111111111111111111111111111".into()), None).unwrap();
        assert_eq!(cfg.decimals, 6);
    }
}
