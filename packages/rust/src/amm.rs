//! Pure constant-product routing math — mirrors
//! packages/contracts/src/libraries/QieForgeLibrary.sol exactly (same
//! 30bps fee, same formulas), so a Rust caller gets the identical quote a
//! real QieForgeRouter.getAmountsOut/getAmountsIn call would return.

use ethers::types::U256;

use crate::errors::QieForgeError;

pub const FEE_BPS: u64 = 30;
pub const BPS_DENOMINATOR: u64 = 10_000;

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
