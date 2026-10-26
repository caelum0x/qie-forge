// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IQieForgeFactory} from "../interfaces/IQieForgeFactory.sol";
import {IQieForgePair} from "../interfaces/IQieForgePair.sol";

/// @title QieForgeLibrary
/// @notice Pure constant-product routing math for QieForgeRouter, derived
/// directly from the x*y=k definition with a 30bps fee deducted from the
/// input leg. These are the two standard high-school-algebra rearrangements
/// of `(x + dx*(1-f)) * (y - dy) = x*y`:
///
///   solve for dy given dx: dy = dx*(1-f)*y / (x + dx*(1-f))
///   solve for dx given dy: dx = x*dy / ((y-dy)*(1-f)), rounded up
///
/// with fee expressed in basis points (30 = 0.30%) to match
/// `QieForgePair.SWAP_FEE_BPS`. Written independently for QIE Forge; no
/// existing router's source was read while deriving this.
library QieForgeLibrary {
    uint256 internal constant FEE_BPS = 30;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error IdenticalAddresses();
    error ZeroAddress();
    error InsufficientAmount();
    error InsufficientLiquidity();
    error InvalidPath();
    error PairNotFound();

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
    }

    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        address pair = IQieForgeFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();
        (uint112 reserve0, uint112 reserve1,) = IQieForgePair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @notice Proportional quote with no fee — used for add/remove liquidity ratio checks, not swaps.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * (BPS_DENOMINATOR - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BPS_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut <= amountOut) revert InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * BPS_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (BPS_DENOMINATOR - FEE_BPS);
        amountIn = numerator / denominator + 1;
    }

    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
