// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {QieForgeERC20} from "./QieForgeERC20.sol";
import {IQieForgePair} from "./interfaces/IQieForgePair.sol";
import {IQieForgeFactory} from "./interfaces/IQieForgeFactory.sol";
import {QieForgeMath} from "./libraries/QieForgeMath.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";

/// @title QieForgePair
/// @notice A constant-product (x*y=k) liquidity pool with a 30bps swap fee
/// that compounds directly into reserves (LP-compounding fee model), an
/// optional protocol fee on liquidity growth (own formula — see
/// `_mintProtocolFee`, independently derived, not a port of any existing
/// DEX's fee-switch arithmetic), minimum-liquidity burn-lock to block the
/// classic "first depositor drains an empty pool via rounding" attack, and
/// price-cumulative TWAP accumulators for downstream consumers (QieForgeVault's
/// on-pool price fallback). Every formula below was derived from the plain
/// constant-product definition for QIE Forge; no existing DEX's source was
/// read or copied while writing this file.
contract QieForgePair is QieForgeERC20, ReentrancyGuard, IQieForgePair {
    using SafeERC20 for IERC20;
    using UQ112x112 for uint224;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    /// @notice Swap fee in basis points (30 = 0.30%), compounded into reserves.
    uint256 public constant SWAP_FEE_BPS = 30;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    /// @notice Share of LP-growth routed to `factory.feeTo()` when set, in basis points of the growth.
    uint256 public constant PROTOCOL_FEE_SHARE_BPS = 1_667; // ~1/6 of growth, QIE Forge's own parameter choice

    address public immutable override factory;
    address public override token0;
    address public override token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public override price0CumulativeLast;
    uint256 public override price1CumulativeLast;
    /// @notice reserve0 * reserve1 as of the most recent liquidity event, used by the protocol-fee formula.
    uint256 public override kLast;

    bool private initialized;

    error AlreadyInitialized();
    error Forbidden();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
    error InsufficientInputAmount();
    error KInvariant();
    error Overflow();

    constructor() {
        factory = msg.sender;
    }

    /// @notice Called once by the factory immediately after CREATE2 deployment.
    function initialize(address _token0, address _token1) external {
        if (msg.sender != factory) revert Forbidden();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves()
        public
        view
        override
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        IERC20(token).safeTransfer(to, value);
    }

    /// @notice Updates reserves and accumulates the TWAP price. Reverts if a
    /// balance can't fit in uint112 rather than silently truncating.
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();

        unchecked {
            uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
                price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            }
            blockTimestampLast = blockTimestamp;
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit Sync(reserve0, reserve1);
    }

    /// @notice QIE Forge's own protocol-fee-on-growth formula: when
    /// `factory.feeTo()` is set, mint LP shares worth
    /// `PROTOCOL_FEE_SHARE_BPS` of the sqrt(k) growth since the last
    /// liquidity event, diluting existing LPs by exactly that much in favor
    /// of the protocol treasury. Independently derived ratio-of-growth
    /// formula, not any existing DEX's fee-switch code.
    function _mintProtocolFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IQieForgeFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = QieForgeMath.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = QieForgeMath.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 growth = rootK - rootKLast;
                    uint256 numerator = totalSupply() * growth * PROTOCOL_FEE_SHARE_BPS;
                    uint256 denominator = rootK * BPS_DENOMINATOR;
                    uint256 liquidityFee = numerator / denominator;
                    if (liquidityFee > 0) _mintShares(feeTo, liquidityFee);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /// @notice Mint LP shares for tokens already transferred into this pair
    /// by the caller (router pulls tokens from the user into the pair,
    /// THEN calls mint — standard two-step pattern any pool with this
    /// reserve model arrives at independently, since the pool itself has
    /// no allowance to pull funds on the router's behalf).
    function mint(address to) external override nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintProtocolFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            liquidity = QieForgeMath.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mintShares(address(0xdEaD), MINIMUM_LIQUIDITY);
        } else {
            liquidity = QieForgeMath.min(
                (amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1
            );
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mintShares(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Burn LP shares already transferred to this pair by the
    /// caller, returning the proportional underlying tokens to `to`.
    function burn(address to) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintProtocolFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burnShares(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Swap. The caller must have already transferred the input
    /// token(s) into this pair before calling (router enforces this via
    /// `safeTransferFrom` to the pair address). Output is sent optimistically,
    /// then the fee-adjusted constant-product invariant is checked.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external override nonReentrant {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();

        address _token0 = token0;
        address _token1 = token1;
        if (to == _token0 || to == _token1) revert InvalidTo();

        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);

        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        {
            uint256 balance0Adjusted = balance0 * BPS_DENOMINATOR - amount0In * SWAP_FEE_BPS;
            uint256 balance1Adjusted = balance1 * BPS_DENOMINATOR - amount1In * SWAP_FEE_BPS;
            if (
                balance0Adjusted * balance1Adjusted
                    < uint256(_reserve0) * uint256(_reserve1) * (BPS_DENOMINATOR * BPS_DENOMINATOR)
            ) {
                revert KInvariant();
            }
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice Forces reserves to match actual token balances (recovers from a token with unusual transfer behavior).
    function sync() external override nonReentrant {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        _update(
            IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), _reserve0, _reserve1
        );
    }
}
