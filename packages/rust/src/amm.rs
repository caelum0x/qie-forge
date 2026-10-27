//! Pure constant-product routing math — mirrors
//! packages/contracts/src/libraries/QieForgeLibrary.sol exactly (same
//! 30bps fee, same formulas), so a Rust caller gets the identical quote a
//! real QieForgeRouter.getAmountsOut/getAmountsIn call would return.

use std::str::FromStr;
use std::sync::Arc;

use ethers::prelude::*;

use crate::chain::ChainClient;
use crate::errors::QieForgeError;

pub const FEE_BPS: u64 = 30;
pub const BPS_DENOMINATOR: u64 = 10_000;

abigen!(
    IQieForgeFactory,
    r#"[
        function getPair(address tokenA, address tokenB) external view returns (address pair)
    ]"#
);

abigen!(
    IQieForgePair,
    r#"[
        function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
        function token0() external view returns (address)
    ]"#
);

abigen!(
    IQieForgeRouter,
    r#"[
        function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) external returns (uint256[] amounts)
        function getAmountsOut(uint256 amountIn, address[] path) external view returns (uint256[] amounts)
    ]"#
);

/// Reads the on-chain reserves for a `tokenA`/`tokenB` pair through the
/// factory — mirrors packages/python/qie_forge/amm.py's `get_reserves`.
pub async fn get_reserves(
    chain: &ChainClient,
    factory_address: Address,
    token_a: Address,
    token_b: Address,
) -> Result<(U256, U256), QieForgeError> {
    let factory = IQieForgeFactory::new(factory_address, Arc::new(chain.provider().clone()));
    let pair_address = factory
        .get_pair(token_a, token_b)
        .call()
        .await
        .map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
    if pair_address == Address::zero() {
        return Err(QieForgeError::InvalidResponse(format!(
            "No pair deployed for {token_a:#x}/{token_b:#x} on {factory_address:#x}"
        )));
    }

    let pair = IQieForgePair::new(pair_address, Arc::new(chain.provider().clone()));
    let (reserve0, reserve1, _ts) =
        pair.get_reserves().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;
    let token0 = pair.token_0().call().await.map_err(|e| QieForgeError::InvalidResponse(e.to_string()))?;

    Ok(if token_a == token0 {
        (U256::from(reserve0), U256::from(reserve1))
    } else {
        (U256::from(reserve1), U256::from(reserve0))
    })
}

/// Walks a multi-hop `path`, reading real on-chain reserves at each hop and
/// applying the same pure quote math as `get_amount_out` — mirrors
/// packages/python/qie_forge/amm.py's `get_amounts_out`. A Rust caller gets
/// the identical quote a real `QieForgeRouter.getAmountsOut()` call would
/// return, without needing a round-trip through the router contract itself.
pub async fn get_amounts_out_onchain(
    chain: &ChainClient,
    factory_address: Address,
    amount_in: U256,
    path: &[Address],
) -> Result<Vec<U256>, QieForgeError> {
    if path.len() < 2 {
        return Err(QieForgeError::InvalidResponse("path must have at least 2 tokens".into()));
    }
    let mut amounts = vec![amount_in];
    for i in 0..path.len() - 1 {
        let (reserve_in, reserve_out) = get_reserves(chain, factory_address, path[i], path[i + 1]).await?;
        let next = get_amount_out(*amounts.last().unwrap(), reserve_in, reserve_out)?;
        amounts.push(next);
    }
    Ok(amounts)
}

/// Builds an UNSIGNED `swapExactTokensForTokens` transaction against a real
/// deployed router — mirrors
/// packages/python/qie_forge/amm.py's `build_swap_exact_tokens_for_tokens_tx`.
/// Never signs or broadcasts; the caller (or a real wallet) is responsible
/// for that.
#[allow(clippy::too_many_arguments)] // mirrors the Python SDK's identical 8-argument signature
pub fn build_swap_exact_tokens_for_tokens_tx(
    chain: &ChainClient,
    router_address: Address,
    amount_in: U256,
    amount_out_min: U256,
    path: Vec<Address>,
    to: Address,
    deadline: U256,
    from_address: Address,
) -> ethers::types::transaction::eip2718::TypedTransaction {
    let router = IQieForgeRouter::new(router_address, Arc::new(chain.provider().clone()));
    router
        .swap_exact_tokens_for_tokens(amount_in, amount_out_min, path, to, deadline)
        .from(from_address)
        .tx
}

pub fn parse_address(address: &str) -> Result<Address, QieForgeError> {
    Address::from_str(address).map_err(|_| QieForgeError::InvalidAddress(address.to_string()))
}

pub fn get_amount_out(amount_in: U256, reserve_in: U256, reserve_out: U256) -> Result<U256, QieForgeError> {
    if amount_in.is_zero() {
        return Err(QieForgeError::InvalidResponse("amountIn must be positive".into()));
    }
    if reserve_in.is_zero() || reserve_out.is_zero() {
        return Err(QieForgeError::InvalidResponse("reserves must be positive".into()));
    }
    let amount_in_with_fee = amount_in * U256::from(BPS_DENOMINATOR - FEE_BPS);
    let numerator = amount_in_with_fee * reserve_out;
    let denominator = reserve_in * U256::from(BPS_DENOMINATOR) + amount_in_with_fee;
    Ok(numerator / denominator)
}

pub fn get_amount_in(amount_out: U256, reserve_in: U256, reserve_out: U256) -> Result<U256, QieForgeError> {
    if amount_out.is_zero() {
        return Err(QieForgeError::InvalidResponse("amountOut must be positive".into()));
    }
    if reserve_in.is_zero() || reserve_out <= amount_out {
        return Err(QieForgeError::InvalidResponse("insufficient liquidity for requested amountOut".into()));
    }
    let numerator = reserve_in * amount_out * U256::from(BPS_DENOMINATOR);
    let denominator = (reserve_out - amount_out) * U256::from(BPS_DENOMINATOR - FEE_BPS);
    Ok(numerator / denominator + U256::one())
}

pub fn quote(amount_a: U256, reserve_a: U256, reserve_b: U256) -> Result<U256, QieForgeError> {
    if amount_a.is_zero() {
        return Err(QieForgeError::InvalidResponse("amountA must be positive".into()));
    }
    if reserve_a.is_zero() || reserve_b.is_zero() {
        return Err(QieForgeError::InvalidResponse("reserves must be positive".into()));
    }
    Ok(amount_a * reserve_b / reserve_a)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wad(n: u64) -> U256 {
        U256::from(n) * U256::exp10(18)
    }

    #[test]
    fn get_amount_out_matches_hand_calculation() {
        let amount_in = wad(100);
        let reserve_in = wad(10_000);
        let reserve_out = wad(10_000);
        let amount_in_with_fee = amount_in * U256::from(9970u64);
        let expected = amount_in_with_fee * reserve_out / (reserve_in * U256::from(10_000u64) + amount_in_with_fee);
        assert_eq!(get_amount_out(amount_in, reserve_in, reserve_out).unwrap(), expected);
        assert!(expected < amount_in);
    }

    #[test]
    fn get_amount_out_and_in_round_trip_within_rounding_error() {
        let reserve_in = wad(50_000);
        let reserve_out = wad(20_000);
        let amount_in = wad(1_000);
        let amount_out = get_amount_out(amount_in, reserve_in, reserve_out).unwrap();
        let recovered_in = get_amount_in(amount_out, reserve_in, reserve_out).unwrap();
        let diff = if recovered_in > amount_in { recovered_in - amount_in } else { amount_in - recovered_in };
        assert!(diff <= U256::from(2u64));
    }

    #[test]
    fn quote_is_proportional() {
        assert_eq!(quote(U256::from(100), U256::from(1000), U256::from(4000)).unwrap(), U256::from(400));
    }

    #[test]
    fn rejects_non_positive_inputs() {
        assert!(get_amount_out(U256::zero(), U256::from(1000), U256::from(1000)).is_err());
        assert!(get_amount_in(U256::from(1000), U256::from(1000), U256::from(500)).is_err());
        assert!(quote(U256::zero(), U256::from(1000), U256::from(1000)).is_err());
    }
}
