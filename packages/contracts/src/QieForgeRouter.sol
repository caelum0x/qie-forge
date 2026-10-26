// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IQieForgeFactory} from "./interfaces/IQieForgeFactory.sol";
import {IQieForgePair} from "./interfaces/IQieForgePair.sol";
import {QieForgeLibrary} from "./libraries/QieForgeLibrary.sol";

/// @title QieForgeRouter
/// @notice Periphery contract: adds/removes liquidity and routes multi-hop
/// swaps across QieForgePair pools. Holds no funds between transactions —
/// every function either pulls from the caller and pushes straight into a
/// pair, or receives pair output and forwards it to the caller, within a
/// single transaction.
contract QieForgeRouter {
    using SafeERC20 for IERC20;

    address public immutable factory;

    error Expired();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();
    error ExcessiveInputAmount();
    error InvalidPath();

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(address _factory) {
        factory = _factory;
    }

    function _pairFor(address tokenA, address tokenB) internal view returns (address pair) {
        pair = IQieForgeFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) revert QieForgeLibrary.PairNotFound();
    }

    // ---------------------------------------------------------------- //
    // Liquidity
    // ---------------------------------------------------------------- //

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        address pair = IQieForgeFactory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = IQieForgeFactory(factory).createPair(tokenA, tokenB);
        }

        (uint256 reserveA, uint256 reserveB) = _tryGetReserves(pair, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = QieForgeLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert InsufficientBAmount();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = QieForgeLibrary.quote(amountBDesired, reserveB, reserveA);
                if (amountAOptimal < amountAMin) revert InsufficientAAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }

        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IQieForgePair(pair).mint(to);
    }

    function _tryGetReserves(address pair, address tokenA, address tokenB)
        private
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        tokenB; // reserved for readability at call sites; pair.token0() is the real source of truth
        (uint112 r0, uint112 r1,) = IQieForgePair(pair).getReserves();
        address pairToken0 = IQieForgePair(pair).token0();
        (reserveA, reserveB) = tokenA == pairToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = _pairFor(tokenA, tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = IQieForgePair(pair).burn(to);
        address token0 = IQieForgePair(pair).token0();
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    // ---------------------------------------------------------------- //
    // Swaps
    // ---------------------------------------------------------------- //

    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = QieForgeLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? _pairFor(path[i + 1], path[i + 2]) : _to;
            IQieForgePair(_pairFor(input, output)).swap(amount0Out, amount1Out, to);
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = QieForgeLibrary.getAmountsOut(factory, amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, _pairFor(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        if (path.length < 2) revert InvalidPath();
        amounts = QieForgeLibrary.getAmountsIn(factory, amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInputAmount();
        IERC20(path[0]).safeTransferFrom(msg.sender, _pairFor(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory) {
        return QieForgeLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory) {
        return QieForgeLibrary.getAmountsIn(factory, amountOut, path);
    }
}
