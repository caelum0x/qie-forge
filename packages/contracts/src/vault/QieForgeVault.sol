// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {QieOracleAdapter} from "../oracle/QieOracleAdapter.sol";

/// @title QieForgeVault
/// @notice Isolated, single-collateral/single-borrow-asset over-collateralized
/// lending vault (a "CDP"-style design: collateral deposits do not earn
/// yield — they exist purely to back borrowing — distinct from a shared
/// money-market pool, which keeps this contract's accounting self-contained
/// and auditable). One vault instance per (collateralAsset, borrowAsset,
/// riskParameters) combination, same pattern isolated-lending-pool designs
/// (e.g. Euler/Fuse-style) independently arrive at to contain one bad
/// asset's risk to its own vault.
///
/// Interest accrues per-user, continuously, via a simple linear
/// rate-per-second applied lazily on each interaction — no shared interest
/// index is needed because collateral deposits here don't earn yield, so
/// there is nothing to socialize interest income across.
contract QieForgeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        uint128 collateral;
        uint128 debtPrincipal;
        uint64 lastAccrual;
    }

    IERC20 public immutable collateralAsset;
    IERC20 public immutable borrowAsset;
    uint8 private immutable collateralDecimals;
    uint8 private immutable borrowDecimals;
    QieOracleAdapter public immutable oracle;

    /// @notice Max borrow at origination, as a fraction of collateral value. 7_500 = 75%.
    uint256 public immutable ltvBps;
    /// @notice Health-factor threshold below which a position is liquidatable. 8_000 = 80%.
    uint256 public immutable liquidationThresholdBps;
    /// @notice Extra collateral (in USD value) a liquidator receives per unit of debt repaid. 500 = 5%.
    uint256 public immutable liquidationBonusBps;
    /// @notice Simple per-second borrow interest rate, scaled 1e18 (e.g. 5% APR ≈ 5e16 / 365 days).
    uint256 public immutable ratePerSecond18;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant WAD = 1e18;

    mapping(address => Position) public positions;
    uint256 public totalCollateral;
    uint256 public totalDebtPrincipal;

    /// @notice Lender share accounting (ERC4626-style, internal — not a
    /// transferable ERC-20). Lenders supply `borrowAsset` and receive shares
    /// of `totalAssets() = idle borrowAsset balance + totalDebtPrincipal`.
    /// Interest accrued via `_accrue` grows `totalDebtPrincipal`, which
    /// grows `totalAssets()` for everyone without a cash movement — this is
    /// also how a liquidation write-off (see `liquidate`) is automatically
    /// socialized across all lenders: shrinking `totalDebtPrincipal` shrinks
    /// every share's claim proportionally, with no separate write-off ledger
    /// needed.
    mapping(address => uint256) public lenderShares;
    uint256 public totalLenderShares;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized
    );
    event BadDebtWrittenOff(address indexed user, uint256 amount);
    event Deposited(address indexed lender, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lender, uint256 amount, uint256 shares);

    error ZeroAmount();
    error InsufficientCollateral();
    error ExceedsLtv();
    error PositionHealthy();
    error RepayExceedsDebt();
    error NothingToLiquidate();
    error InsufficientShares();
    error InsufficientLiquidity();

    constructor(
        IERC20 _collateralAsset,
        IERC20 _borrowAsset,
        QieOracleAdapter _oracle,
        uint256 _ltvBps,
        uint256 _liquidationThresholdBps,
        uint256 _liquidationBonusBps,
        uint256 _ratePerSecond18
    ) {
        collateralAsset = _collateralAsset;
        borrowAsset = _borrowAsset;
        oracle = _oracle;
        ltvBps = _ltvBps;
        liquidationThresholdBps = _liquidationThresholdBps;
        liquidationBonusBps = _liquidationBonusBps;
        ratePerSecond18 = _ratePerSecond18;
        collateralDecimals = IERC20Metadata(address(_collateralAsset)).decimals();
        borrowDecimals = IERC20Metadata(address(_borrowAsset)).decimals();
    }

    // ---------------------------------------------------------------- //
    // Internal accounting
    // ---------------------------------------------------------------- //

    /// @dev Applies simple per-second interest since the position's last
    /// touch: debt += debt * rate * elapsed / 1e18. Lazy accrual avoids a
    /// global index since collateral here earns no yield to socialize.
    function _accrue(Position storage pos) internal returns (uint256 debt) {
        debt = pos.debtPrincipal;
        if (debt == 0) {
            pos.lastAccrual = uint64(block.timestamp);
            return 0;
        }
        uint256 elapsed = block.timestamp - pos.lastAccrual;
        if (elapsed > 0) {
            uint256 interest = (debt * ratePerSecond18 * elapsed) / WAD;
            if (interest > 0) {
                totalDebtPrincipal = totalDebtPrincipal - debt + (debt + interest);
                debt += interest;
                pos.debtPrincipal = uint128(debt);
            }
            pos.lastAccrual = uint64(block.timestamp);
        }
    }

    function _usdValue(uint256 amount, uint8 tokenDecimals, uint256 price18) private pure returns (uint256) {
        return (amount * price18) / (10 ** tokenDecimals);
    }

    /// @notice Health factor scaled 1e18. >= 1e18 is safe; < 1e18 is liquidatable.
    /// HF = (collateralValueUsd * liquidationThresholdBps) / (debtValueUsd * BPS_DENOMINATOR)
    function healthFactor(address user) public view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.debtPrincipal == 0) return type(uint256).max;

        uint256 collateralValue =
            _usdValue(pos.collateral, collateralDecimals, oracle.getPriceUsd18(address(collateralAsset)));
        uint256 debtValue = _usdValue(pos.debtPrincipal, borrowDecimals, oracle.getPriceUsd18(address(borrowAsset)));
        if (debtValue == 0) return type(uint256).max;

        return (collateralValue * liquidationThresholdBps * WAD) / (debtValue * BPS_DENOMINATOR);
    }

    // ---------------------------------------------------------------- //
    // Lender actions
    // ---------------------------------------------------------------- //

    /// @notice Total value backing all lender shares: the vault's own idle
    /// `borrowAsset` balance (undeployed liquidity) plus all outstanding
    /// debt principal (interest-inclusive, per `_accrue`), which is the
    /// claim the vault still has on borrowers.
    function totalAssets() public view returns (uint256) {
        return borrowAsset.balanceOf(address(this)) + totalDebtPrincipal;
    }

    /// @notice Supply `borrowAsset` liquidity and receive shares priced at
    /// the current exchange rate. First depositor mints 1:1.
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        uint256 assetsBefore = totalAssets();
        shares = totalLenderShares == 0 ? amount : (amount * totalLenderShares) / assetsBefore;
        if (shares == 0) revert ZeroAmount();

        lenderShares[msg.sender] += shares;
        totalLenderShares += shares;
        borrowAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, shares);
    }

    /// @notice Redeem shares for `borrowAsset` at the current exchange rate.
    /// Reverts if the vault's idle balance can't cover it (liquidity
    /// currently out on loan isn't withdrawable until repaid).
    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        if (shares > lenderShares[msg.sender]) revert InsufficientShares();

        amount = (shares * totalAssets()) / totalLenderShares;
        uint256 idle = borrowAsset.balanceOf(address(this));
        if (amount > idle) revert InsufficientLiquidity();

        lenderShares[msg.sender] -= shares;
        totalLenderShares -= shares;
        borrowAsset.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, shares);
    }

    // ---------------------------------------------------------------- //
    // User actions
    // ---------------------------------------------------------------- //

    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        _accrue(pos);
        collateralAsset.safeTransferFrom(msg.sender, address(this), amount);
        pos.collateral += uint128(amount);
        totalCollateral += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        _accrue(pos);
        if (pos.collateral < amount) revert InsufficientCollateral();

        pos.collateral -= uint128(amount);
        totalCollateral -= amount;

        if (pos.debtPrincipal > 0) {
            uint256 collateralValue =
                _usdValue(pos.collateral, collateralDecimals, oracle.getPriceUsd18(address(collateralAsset)));
            uint256 debtValue =
                _usdValue(pos.debtPrincipal, borrowDecimals, oracle.getPriceUsd18(address(borrowAsset)));
            if (collateralValue * ltvBps < debtValue * BPS_DENOMINATOR) revert ExceedsLtv();
        }

        collateralAsset.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        uint256 debt = _accrue(pos);

        uint256 newDebt = debt + amount;
        uint256 collateralValue =
            _usdValue(pos.collateral, collateralDecimals, oracle.getPriceUsd18(address(collateralAsset)));
        uint256 newDebtValue = _usdValue(newDebt, borrowDecimals, oracle.getPriceUsd18(address(borrowAsset)));
        if (collateralValue * ltvBps < newDebtValue * BPS_DENOMINATOR) revert ExceedsLtv();

        totalDebtPrincipal = totalDebtPrincipal - debt + newDebt;
        pos.debtPrincipal = uint128(newDebt);
        borrowAsset.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        uint256 debt = _accrue(pos);
        if (amount > debt) revert RepayExceedsDebt();

        uint256 newDebt = debt - amount;
        totalDebtPrincipal = totalDebtPrincipal - debt + newDebt;
        pos.debtPrincipal = uint128(newDebt);
        borrowAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit Repaid(msg.sender, amount);
    }

    /// @notice Anyone may liquidate an unhealthy position by repaying up to
    /// its full debt and receiving collateral worth `repayAmount *
    /// (1 + liquidationBonusBps)` in USD terms, at current oracle prices.
    /// If the position's collateral is fully exhausted by the seizure, the
    /// repay amount is capped down to what that collateral actually covers
    /// (at the bonus rate) and any remaining debt is written off — debt and
    /// collateral always reach zero together, never debt-with-no-collateral.
    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        Position storage pos = positions[user];
        uint256 debt = _accrue(pos);
        if (debt == 0) revert NothingToLiquidate();
        if (healthFactor(user) >= WAD) revert PositionHealthy();
        if (repayAmount > debt) repayAmount = debt;

        uint256 collateralPrice18 = oracle.getPriceUsd18(address(collateralAsset));
        uint256 borrowPrice18 = oracle.getPriceUsd18(address(borrowAsset));

        uint256 repayValueUsd = _usdValue(repayAmount, borrowDecimals, borrowPrice18);
        uint256 seizeValueUsd = (repayValueUsd * (BPS_DENOMINATOR + liquidationBonusBps)) / BPS_DENOMINATOR;
        uint256 seizeCollateral = (seizeValueUsd * (10 ** collateralDecimals)) / collateralPrice18;

        uint256 badDebt;
        if (seizeCollateral >= pos.collateral) {
            // Collateral is the binding constraint. Seize all of it, cap the
            // actual repay to what that collateral is worth at the bonus
            // rate (never more than the liquidator offered), and write off
            // whatever debt remains uncovered instead of leaving it parked
            // on a position with zero collateral behind it.
            seizeCollateral = pos.collateral;
            uint256 seizedValueUsd = _usdValue(seizeCollateral, collateralDecimals, collateralPrice18);
            uint256 coveredValueUsd = (seizedValueUsd * BPS_DENOMINATOR) / (BPS_DENOMINATOR + liquidationBonusBps);
            uint256 coveredRepay = (coveredValueUsd * (10 ** borrowDecimals)) / borrowPrice18;
            if (coveredRepay < repayAmount) repayAmount = coveredRepay;
            badDebt = debt - repayAmount;
        }

        uint256 newDebt = debt - repayAmount - badDebt;
        totalDebtPrincipal = totalDebtPrincipal - debt + newDebt;
        pos.debtPrincipal = uint128(newDebt);
        pos.collateral -= uint128(seizeCollateral);
        totalCollateral -= seizeCollateral;

        if (repayAmount > 0) borrowAsset.safeTransferFrom(msg.sender, address(this), repayAmount);
        if (seizeCollateral > 0) collateralAsset.safeTransfer(msg.sender, seizeCollateral);
        if (badDebt > 0) emit BadDebtWrittenOff(user, badDebt);
        emit Liquidated(user, msg.sender, repayAmount, seizeCollateral);
    }

    function currentDebt(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.debtPrincipal == 0) return 0;
        uint256 elapsed = block.timestamp - pos.lastAccrual;
        uint256 interest = (uint256(pos.debtPrincipal) * ratePerSecond18 * elapsed) / WAD;
        return pos.debtPrincipal + interest;
    }
}
