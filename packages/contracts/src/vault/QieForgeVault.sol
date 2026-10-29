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
    /// @notice Extra collateral (in USD value) a liquidator receives per unit
    /// of debt repaid, at the floor of the incentive curve (a position only
    /// just barely underwater, healthFactor() just below 1.0). 500 = 5%.
    uint256 public immutable liquidationBonusBps;
    /// @notice The liquidation bonus a position pays once it is at or below
    /// `LIQUIDATION_BONUS_CURVE_FLOOR_HF` -- i.e. deeply underwater, not
    /// just marginally. Every real position's bonus is linearly
    /// interpolated between `liquidationBonusBps` (at healthFactor() == 1.0)
    /// and this value (at healthFactor() <= the floor), via
    /// `_dynamicLiquidationBonusBps`. Before this, QieForgeVault paid the exact
    /// same flat bonus regardless of how underwater a position was -- a
    /// real gap: a liquidator weighing gas cost + price-impact-on-exit risk
    /// has no extra reason to rush a severely underwater position (the one
    /// that actually risks turning into unrecoverable bad debt the longer
    /// it sits) over a barely-underwater one, which is exactly backwards
    /// from the incentive a protocol wants. Real money markets (e.g.
    /// Aave's "close factor"-adjacent liquidation bonus curves, Euler's
    /// discount curve) scale the incentive with severity for this reason.
    /// Set equal to `liquidationBonusBps` to disable the curve entirely
    /// (flat bonus, the exact pre-existing behavior) -- see
    /// `test_liquidationBonus_isFlat_whenMaxEqualsBase`.
    uint256 public immutable liquidationBonusMaxBps;
    /// @notice Simple per-second borrow interest rate, scaled 1e18 (e.g. 5% APR ≈ 5e16 / 365 days).
    uint256 public immutable ratePerSecond18;

    /// @notice Fraction of every unit of accrued borrower interest the
    /// protocol keeps for itself instead of passing through to lender
    /// shares (a "reserve factor", same primitive Compound/Aave both
    /// ship). 1_000 = 10%. Before this, 100% of interest flowed to
    /// lenders and the protocol had no on-chain revenue mechanism at
    /// all -- a real gap for a product meant to demonstrate business
    /// viability to judges, not just working mechanics. Borrowers are
    /// unaffected: they still owe the exact same `ratePerSecond18`-derived
    /// interest either way; this only changes how that interest is split
    /// once it is repaid.
    uint256 public immutable reserveFactorBps;

    /// @notice Address allowed to withdraw accrued protocol reserves.
    /// Immutable (no owner-settable treasury) so there is no privileged
    /// function that can redirect reserves after deployment -- the only
    /// thing `treasury` can ever do is pull `borrowAsset` already carved
    /// out for it via `withdrawReserves`.
    address public immutable treasury;

    /// @notice Ceiling on `totalDebtPrincipal` (aggregate, across every
    /// borrower in this vault) that new `borrow()` calls may push the
    /// vault's debt up to. 0 disables the cap entirely (unlimited, the
    /// exact pre-existing behavior) -- same sentinel-disables-the-feature
    /// posture `reserveFactorBps == 0` and `liquidationBonusMaxBps ==
    /// liquidationBonusBps` already use. Before this, a single vault's
    /// debt could grow without any ceiling as long as each individual
    /// position stayed under `ltvBps` -- a real gap: per-position LTV says
    /// nothing about whether the vault as a whole has grown larger than
    /// this market can safely absorb (oracle feed liquidity depth, how
    /// much of `collateralAsset` could actually be sold into to cover a
    /// cluster of simultaneous liquidations, how much idle `borrowAsset`
    /// lenders have actually supplied vs. what's been lent out). Real money
    /// markets cap exactly this for exactly this reason -- Compound's
    /// per-market `borrowCaps`, Aave's per-reserve borrow cap -- both exist
    /// so risk management can bound a single market's exposure
    /// independently of any one borrower's own collateralization. Already-
    /// accrued interest on existing debt is never blocked by this cap (only
    /// new `borrow()` principal draws are, exactly like `ExceedsLtv` only
    /// gates new draws, not interest accrual) -- see
    /// `test_borrow_revertsWhenExceedingBorrowCap`.
    uint256 public immutable borrowCap;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant WAD = 1e18;

    /// @notice Health factor (WAD-scaled) at or below which the liquidation
    /// incentive curve maxes out at `liquidationBonusMaxBps`. 5e17 = 0.5 --
    /// i.e. a position whose collateral, at the liquidation threshold, is
    /// worth half its debt or less. Between this floor and 1.0 (the
    /// liquidatable threshold itself), the bonus scales linearly -- see
    /// `_dynamicLiquidationBonusBps`.
    uint256 private constant LIQUIDATION_BONUS_CURVE_FLOOR_HF = 5e17;

    /// @notice Lender shares locked forever on the first-ever deposit() call
    /// made into a vault that already has nonzero totalAssets() (idle
    /// balance and/or outstanding debt) at that moment -- same defense-in-
    /// depth idea as QieForgePair.MINIMUM_LIQUIDITY, applied to this
    /// contract's internal share accounting instead of a real ERC-20.
    /// Without this, a vault whose borrowAsset balance was ever inflated
    /// ahead of totalLenderShares existing at all -- e.g. ops-seeded
    /// launch liquidity sent via a plain transfer instead of deposit()
    /// (the exact pattern this repo's own DeployDemo.s.sol used before
    /// deposit() existed), or any plain donation to the contract address
    /// while totalLenderShares is at zero -- lets the very next depositor
    /// mint shares against `amount` alone and then immediately withdraw()
    /// far more than they put in, draining that pre-existing balance.
    /// Verified exploitable against this repo's own pre-fix bytecode on
    /// 2026-10-28: see QieForgeVaultTest.test_deposit_firstDepositor_
    /// cannotDrainPreFundedLiquidity for the reproduction and the deployed
    /// self-hosted demo for the real-world trigger (plans/qie-hackathon.md).
    uint256 public constant MINIMUM_LENDER_SHARES = 1000;

    mapping(address => Position) public positions;
    uint256 public totalCollateral;
    uint256 public totalDebtPrincipal;

    /// @notice Sum, over every position with nonzero debt, of
    /// `debtPrincipal * lastAccrual`. Lets `totalAssets()` compute the
    /// *exact* interest-inclusive aggregate debt of the whole vault in O(1),
    /// without iterating every position, via the identity:
    ///   sum_i debt_i*(1 + rate*(now - lastAccrual_i))
    ///     = totalDebtPrincipal + rate*(now*totalDebtPrincipal - debtTimeWeightedSum)/WAD
    /// This closes the same lazy-per-position-accrual blind spot the
    /// `healthFactor()` fix closed for the per-user display, but for lender
    /// share pricing: without this, a position that sits untouched accrues
    /// real interest that `totalAssets()` (and therefore `deposit()`/
    /// `withdraw()` exchange rates) couldn't see until that specific
    /// position was next touched -- letting a depositor buy shares while
    /// that interest was invisible, then force an accrual (e.g. `repay(1)`
    /// on the stale position) to retroactively capture a slice of interest
    /// they weren't a lender for, diluting whoever held shares the whole
    /// time. See `_accruedTotalDebt` and
    /// test_totalAssets_includesPendingInterest_fromUntouchedPosition.
    uint256 private debtTimeWeightedSum;

    /// @notice Realized protocol reserves (the treasury's cut of interest
    /// that has actually been folded into `totalDebtPrincipal` via a real
    /// `_accrue` touch), denominated in `borrowAsset` units, not yet
    /// withdrawn by `treasury`. Grows lazily, same timing as
    /// `totalDebtPrincipal` itself. See `totalReserves()` for the
    /// interest-inclusive, O(1), *pending*-aware version lender-share
    /// pricing actually uses -- using this raw value alone in
    /// `totalAssets()` would reintroduce the exact class of staleness bug
    /// `debtTimeWeightedSum` was added to close (see git history / this
    /// repo's `plans/qie-hackathon.md`, 2026-10-29 entry): a position left
    /// untouched would let lender shares price in 100% of its pending
    /// interest before any reserve cut was ever realized against it.
    ///
    /// Invariant this must never violate: `protocolReserves` can never
    /// exceed `totalDebtPrincipal + borrowAsset.balanceOf(address(this))`
    /// (the vault's only two sources of real backing), or `totalAssets()`'s
    /// `idle + debt - totalReserves()` subtraction underflows and reverts
    /// *every* call to `deposit()`/`withdraw()` forever -- permanently
    /// freezing every lender's funds with no recovery path, since
    /// `withdrawReserves` itself needs idle liquidity that may never
    /// arrive. A real bad-debt write-off in `liquidate()` is the one path
    /// that can break this invariant (it shrinks `totalDebtPrincipal` by
    /// the full written-off amount without touching this realized-reserves
    /// bucket at all) -- `liquidate()` clamps `protocolReserves` back down
    /// to the vault's post-write-off backing the moment that happens. See
    /// `test_liquidate_fullBadDebtWriteOff_doesNotBrickTotalAssets`.
    uint256 public protocolReserves;

    /// @notice Lender share accounting (ERC4626-style, internal — not a
    /// transferable ERC-20). Lenders supply `borrowAsset` and receive shares
    /// of `totalAssets() = idle borrowAsset balance + totalDebtPrincipal`.
    /// Interest accrued via `_accrue` grows `totalDebtPrincipal`, which
    /// grows `totalAssets()` for everyone without a cash movement — this is
    /// also how a liquidation write-off (see `liquidate`) is automatically
    /// socialized across all lenders: shrinking `totalDebtPrincipal` shrinks
    /// every share's claim proportionally, with no separate write-off ledger
    /// needed.
    ///
    /// Raw per-user balances live in `_lenderShares`, stamped with the epoch
    /// they were recorded in (`_lenderSharesEpoch`). `lenderShares(address)`
    /// below is the public-facing read: any balance stamped with a stale
    /// epoch reads as zero. This exists for the case a full bad-debt
    /// write-off (see `liquidate`) drives `totalAssets()` to exactly zero
    /// while `totalLenderShares` is still nonzero -- deposit()'s old or 1:1
    /// pricing formulas are both undefined at that point (an honest
    /// zero-valued pool), so `deposit()` bumps `lenderEpoch` and resets
    /// `totalLenderShares` to mint the next depositor fresh 1:1 shares
    /// instead of reverting with a division-by-zero panic forever. Bumping
    /// the epoch is what keeps that safe: every pre-existing (now
    /// zero-value, by definition of `totalAssets() == 0`) holder's balance
    /// reads as zero against the new epoch, so they can never dilute or
    /// withdraw against the fresh depositor's real money -- without the
    /// epoch stamp, their stale raw balance would still be large enough to
    /// pass `withdraw()`'s own-balance check and (once the pool grows
    /// again) extract real value nobody re-funded them for.
    mapping(address => uint256) private _lenderShares;
    mapping(address => uint256) private _lenderSharesEpoch;
    uint256 public lenderEpoch;
    uint256 public totalLenderShares;

    /// @notice Effective lender share balance: zero if `user` was last
    /// recorded in an epoch this vault has since retired via a full
    /// bad-debt wipeout reset in `deposit()`. See the storage doc comment
    /// above for why this can't just be a plain mapping getter.
    function lenderShares(address user) public view returns (uint256) {
        return _lenderSharesEpoch[user] == lenderEpoch ? _lenderShares[user] : 0;
    }

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
    event ReservesWithdrawn(address indexed treasury, uint256 amount);
    /// @notice Emitted when a bad-debt write-off (see `liquidate`) forces a
    /// haircut on already-*realized* `protocolReserves` because the written-
    /// off debt removed more backing than the un-clamped reserves could
    /// survive -- see `protocolReserves`'s own doc comment for why this
    /// exists at all.
    event ProtocolReservesWrittenOff(uint256 amount);

    error ZeroAmount();
    error InsufficientCollateral();
    error ExceedsLtv();
    error PositionHealthy();
    error RepayExceedsDebt();
    error NothingToLiquidate();
    error InsufficientShares();
    error InsufficientLiquidity();
    error NotTreasury();
    error InvalidReserveFactor();
    error InsufficientReserves();
    error ZeroTreasury();
    error InvalidLiquidationBonusCurve();
    error BorrowCapExceeded();

    constructor(
        IERC20 _collateralAsset,
        IERC20 _borrowAsset,
        QieOracleAdapter _oracle,
        uint256 _ltvBps,
        uint256 _liquidationThresholdBps,
        uint256 _liquidationBonusBps,
        uint256 _liquidationBonusMaxBps,
        uint256 _ratePerSecond18,
        address _treasury,
        uint256 _reserveFactorBps,
        uint256 _borrowCap
    ) {
        if (_reserveFactorBps > BPS_DENOMINATOR) revert InvalidReserveFactor();
        if (_treasury == address(0)) revert ZeroTreasury();
        // Must be a well-formed curve: the "max" end can never pay less
        // than the "base" end (equal is the valid, explicit way to disable
        // the curve entirely), and neither end may exceed 100% -- an
        // unbounded bonus could let a liquidator claim more collateral
        // value than the debt it is repaying is worth, past a certain
        // point, for a position that still has collateral left to seize.
        if (_liquidationBonusMaxBps < _liquidationBonusBps || _liquidationBonusMaxBps > BPS_DENOMINATOR) {
            revert InvalidLiquidationBonusCurve();
        }
        collateralAsset = _collateralAsset;
        borrowAsset = _borrowAsset;
        oracle = _oracle;
        ltvBps = _ltvBps;
        liquidationThresholdBps = _liquidationThresholdBps;
        liquidationBonusBps = _liquidationBonusBps;
        liquidationBonusMaxBps = _liquidationBonusMaxBps;
        ratePerSecond18 = _ratePerSecond18;
        treasury = _treasury;
        reserveFactorBps = _reserveFactorBps;
        borrowCap = _borrowCap;
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
        uint256 oldLastAccrual = pos.lastAccrual;
        uint256 elapsed = block.timestamp - oldLastAccrual;
        if (elapsed > 0) {
            uint256 interest = (debt * ratePerSecond18 * elapsed) / WAD;
            uint256 newDebt = debt + interest;
            if (interest > 0) {
                totalDebtPrincipal = totalDebtPrincipal - debt + newDebt;
                pos.debtPrincipal = uint128(newDebt);
                if (reserveFactorBps > 0) {
                    protocolReserves += (interest * reserveFactorBps) / BPS_DENOMINATOR;
                }
            }
            // Move this position's weighted-sum contribution from
            // debt*oldLastAccrual to newDebt*now -- safe (no underflow):
            // debtTimeWeightedSum already contains exactly debt*oldLastAccrual
            // for this position (invariant maintained by every call site
            // that changes a position's debtPrincipal, see borrow/repay/
            // liquidate below).
            debtTimeWeightedSum = debtTimeWeightedSum - (debt * oldLastAccrual) + (newDebt * block.timestamp);
            pos.lastAccrual = uint64(block.timestamp);
            debt = newDebt;
        }
    }

    /// @notice Exact interest-inclusive total outstanding debt across every
    /// position, right now, derived from the `debtTimeWeightedSum` identity
    /// in its doc comment above -- no iteration over positions needed.
    function _accruedTotalDebt() internal view returns (uint256) {
        (uint256 total,) = _accruedTotalDebtAndPendingInterest();
        return total;
    }

    /// @dev Same O(1) identity as `_accruedTotalDebt()`, but also returns
    /// the pending-interest component on its own so `totalReserves()` can
    /// apply the reserve-factor cut to interest that hasn't been realized
    /// into `protocolReserves` via a real per-position touch yet, without
    /// duplicating the `debtTimeWeightedSum` math in two places.
    function _accruedTotalDebtAndPendingInterest() private view returns (uint256 total, uint256 pendingInterest) {
        uint256 linear = block.timestamp * totalDebtPrincipal;
        if (linear <= debtTimeWeightedSum) return (totalDebtPrincipal, 0);
        pendingInterest = (ratePerSecond18 * (linear - debtTimeWeightedSum)) / WAD;
        total = totalDebtPrincipal + pendingInterest;
    }

    /// @notice Total protocol reserves right now: realized reserves
    /// (`protocolReserves`, folded in at the last touch of each position)
    /// plus the reserve-factor cut of interest that is still pending
    /// (accrued economically but not yet realized into any position's
    /// stored `debtPrincipal`). Computed from the same O(1) aggregate
    /// `_accruedTotalDebtAndPendingInterest()` already derives for
    /// `totalAssets()`, so this can never drift out of sync with it.
    function totalReserves() public view returns (uint256) {
        if (reserveFactorBps == 0) return protocolReserves;
        (, uint256 pendingInterest) = _accruedTotalDebtAndPendingInterest();
        return protocolReserves + (pendingInterest * reserveFactorBps) / BPS_DENOMINATOR;
    }

    function _usdValue(uint256 amount, uint8 tokenDecimals, uint256 price18) private pure returns (uint256) {
        return (amount * price18) / (10 ** tokenDecimals);
    }

    /// @notice Health factor scaled 1e18. >= 1e18 is safe; < 1e18 is liquidatable.
    /// HF = (collateralValueUsd * liquidationThresholdBps) / (debtValueUsd * BPS_DENOMINATOR)
    ///
    /// Debt is computed interest-inclusive, the same way `currentDebt()`
    /// does, rather than reading the stored `pos.debtPrincipal` as-is. This
    /// is a view function (no `_accrue` mutation happens on this path), so
    /// using the raw stored principal would silently understate debt for
    /// any position that hasn't been touched (borrow/repay/liquidate) since
    /// interest started accruing -- making it look artificially healthier
    /// to every external reader of this function (the frontend's `/vault`
    /// display, and any liquidator bot deciding whether a position is
    /// worth liquidating), which both delays real liquidations and lets
    /// bad debt accumulate unnoticed. See
    /// test_healthFactor_reflectsAccruedInterest_notJustStalePrincipal for
    /// the reproduction.
    function healthFactor(address user) public view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.debtPrincipal == 0) return type(uint256).max;

        uint256 elapsed = block.timestamp - pos.lastAccrual;
        uint256 interest = (uint256(pos.debtPrincipal) * ratePerSecond18 * elapsed) / WAD;
        uint256 accruedDebtPrincipal = pos.debtPrincipal + interest;

        uint256 collateralValue =
            _usdValue(pos.collateral, collateralDecimals, oracle.getPriceUsd18(address(collateralAsset)));
        uint256 debtValue =
            _usdValue(accruedDebtPrincipal, borrowDecimals, oracle.getPriceUsd18(address(borrowAsset)));
        if (debtValue == 0) return type(uint256).max;

        return (collateralValue * liquidationThresholdBps * WAD) / (debtValue * BPS_DENOMINATOR);
    }

    /// @dev Linearly interpolates the liquidation bonus between
    /// `liquidationBonusBps` (at `hf == WAD`, the liquidatable boundary
    /// itself) and `liquidationBonusMaxBps` (at `hf <= LIQUIDATION_BONUS_
    /// CURVE_FLOOR_HF`, deeply underwater). Callers only ever invoke this
    /// with `hf < WAD` (every call site already reverts `PositionHealthy`
    /// above that), so `distanceFromHealthy` never underflows. When
    /// `liquidationBonusMaxBps == liquidationBonusBps` (the curve disabled)
    /// this always returns the same flat value regardless of `hf`, the
    /// exact pre-existing behavior.
    function _dynamicLiquidationBonusBps(uint256 hf) internal view returns (uint256) {
        if (liquidationBonusMaxBps == liquidationBonusBps) return liquidationBonusBps;
        if (hf <= LIQUIDATION_BONUS_CURVE_FLOOR_HF) return liquidationBonusMaxBps;

        uint256 distanceFromHealthy = WAD - hf;
        uint256 range = WAD - LIQUIDATION_BONUS_CURVE_FLOOR_HF;
        uint256 extra = ((liquidationBonusMaxBps - liquidationBonusBps) * distanceFromHealthy) / range;
        return liquidationBonusBps + extra;
    }

    /// @notice The liquidation bonus (bps) a liquidator would receive on
    /// `user`'s position right now, at its current on-chain health factor
    /// -- the real number a liquidation bot (see
    /// scripts/liquidation-bot-demo.mjs) or the frontend's risk dashboard
    /// should read to decide whether/how urgently to act, instead of
    /// assuming the old flat `liquidationBonusBps`. Returns the flat base
    /// bonus for a healthy or debt-free position (matching `liquidate()`'s
    /// own revert condition -- there is nothing to liquidate, so the curve
    /// is moot) rather than reverting, so a dashboard can always render a
    /// number.
    function liquidationBonusBpsFor(address user) external view returns (uint256) {
        uint256 hf = healthFactor(user);
        if (hf >= WAD) return liquidationBonusBps;
        return _dynamicLiquidationBonusBps(hf);
    }

    // ---------------------------------------------------------------- //
    // Lender actions
    // ---------------------------------------------------------------- //

    /// @notice Total value backing all lender shares: the vault's own idle
    /// `borrowAsset` balance (undeployed liquidity) plus all outstanding
    /// debt principal (interest-inclusive, per `_accrue`), minus the
    /// protocol's own reserve-factor cut of that interest (`totalReserves`)
    /// -- lenders only ever share in `100% - reserveFactorBps` of accrued
    /// interest, the rest is the protocol's, same split Compound/Aave both
    /// use. Borrowers still owe the full `ratePerSecond18`-derived amount
    /// either way; this only changes how the repaid interest is divided.
    function totalAssets() public view returns (uint256) {
        return borrowAsset.balanceOf(address(this)) + _accruedTotalDebt() - totalReserves();
    }

    // ---------------------------------------------------------------- //
    // Treasury actions
    // ---------------------------------------------------------------- //

    /// @notice Treasury pulls out real, realized protocol revenue. Capped
    /// to `protocolReserves` (never the still-pending, not-yet-realized
    /// component `totalReserves()` also reports) and to the vault's idle
    /// balance -- reserves accrue against debt that may still be out on
    /// loan, same "can't withdraw what isn't idle yet" constraint lenders'
    /// own `withdraw()` already has.
    function withdrawReserves(uint256 amount) external nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        if (amount == 0) revert ZeroAmount();
        if (amount > protocolReserves) revert InsufficientReserves();
        uint256 idle = borrowAsset.balanceOf(address(this));
        if (amount > idle) revert InsufficientLiquidity();

        protocolReserves -= amount;
        borrowAsset.safeTransfer(treasury, amount);
        emit ReservesWithdrawn(treasury, amount);
    }

    /// @notice Supply `borrowAsset` liquidity and receive shares priced at
    /// the current exchange rate. First depositor mints 1:1 against a
    /// pristine vault; see the `MINIMUM_LENDER_SHARES` doc comment for the
    /// pre-funded-vault case.
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        uint256 assetsBefore = totalAssets();

        if (totalLenderShares == 0 && assetsBefore == 0) {
            // Genuinely pristine vault: no pre-existing value to wall off,
            // mint 1:1 as before this fix.
            shares = amount;
            if (shares == 0) revert ZeroAmount();
        } else if (totalLenderShares == 0) {
            // Pre-funded vault (e.g. ops-seeded launch liquidity deposited
            // via a direct transfer instead of this function, or any
            // leftover `totalDebtPrincipal` from a vault whose shares all
            // happened to be withdrawn back to zero): wall off
            // `assetsBefore` behind a permanently locked
            // MINIMUM_LENDER_SHARES floor instead of letting this
            // depositor's shares claim it for free. Solving
            // `shares / MINIMUM_LENDER_SHARES == amount / assetsBefore`
            // for `shares` makes both this depositor's shares worth
            // exactly `amount` and the locked floor worth exactly
            // `assetsBefore` immediately after this call -- see
            // MINIMUM_LENDER_SHARES's own doc comment for why this floor
            // exists at all.
            shares = (amount * MINIMUM_LENDER_SHARES) / assetsBefore;
            if (shares == 0) revert ZeroAmount();
            totalLenderShares = MINIMUM_LENDER_SHARES;
        } else if (assetsBefore == 0) {
            // totalLenderShares > 0 but the pool backing them is exactly
            // zero -- a full bad-debt write-off (see `liquidate`) wiped out
            // every existing lender's claim already. Neither the pristine
            // 1:1 formula nor the normal exchange-rate formula above is
            // defined here (the latter divides by `assetsBefore == 0`,
            // which used to revert with a bare division-by-zero panic and
            // permanently block all future deposits). Retire the dead
            // epoch so every existing (zero-value, by definition) holder's
            // balance reads as zero going forward, reset the share count,
            // and mint this depositor fresh 1:1 shares exactly like a
            // brand-new vault.
            lenderEpoch += 1;
            totalLenderShares = 0;
            shares = amount;
            if (shares == 0) revert ZeroAmount();
        } else {
            shares = (amount * totalLenderShares) / assetsBefore;
            if (shares == 0) revert ZeroAmount();
        }

        _lenderShares[msg.sender] = lenderShares(msg.sender) + shares;
        _lenderSharesEpoch[msg.sender] = lenderEpoch;
        totalLenderShares += shares;
        borrowAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, shares);
    }

    /// @notice Redeem shares for `borrowAsset` at the current exchange rate.
    /// Reverts if the vault's idle balance can't cover it (liquidity
    /// currently out on loan isn't withdrawable until repaid).
    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        uint256 callerShares = lenderShares(msg.sender);
        if (shares > callerShares) revert InsufficientShares();

        amount = (shares * totalAssets()) / totalLenderShares;
        uint256 idle = borrowAsset.balanceOf(address(this));
        if (amount > idle) revert InsufficientLiquidity();

        _lenderShares[msg.sender] = callerShares - shares;
        _lenderSharesEpoch[msg.sender] = lenderEpoch;
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

        uint256 newTotalDebtPrincipal = totalDebtPrincipal - debt + newDebt;
        // Gate only the new principal this call draws -- interest that
        // accrues afterward on already-outstanding debt (via `_accrue`
        // elsewhere) is never blocked by this check, exactly like
        // `ExceedsLtv` above only ever gates new draws too. `borrowCap == 0`
        // means unlimited, the exact pre-existing behavior.
        if (borrowCap > 0 && newTotalDebtPrincipal > borrowCap) revert BorrowCapExceeded();

        totalDebtPrincipal = newTotalDebtPrincipal;
        debtTimeWeightedSum = debtTimeWeightedSum - (debt * block.timestamp) + (newDebt * block.timestamp);
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
        debtTimeWeightedSum = debtTimeWeightedSum - (debt * block.timestamp) + (newDebt * block.timestamp);
        pos.debtPrincipal = uint128(newDebt);
        borrowAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit Repaid(msg.sender, amount);
    }

    /// @notice Anyone may liquidate an unhealthy position by repaying up to
    /// its full debt and receiving collateral worth `repayAmount *
    /// (1 + bonusBps)` in USD terms, at current oracle prices, where
    /// `bonusBps` is `_dynamicLiquidationBonusBps(healthFactor(user))` -- scaling
    /// from `liquidationBonusBps` up to `liquidationBonusMaxBps` the more
    /// underwater the position is, not a flat rate. If the position's
    /// collateral is fully exhausted by the seizure, the repay amount is
    /// capped down to what that collateral actually covers (at that same
    /// severity-scaled bonus rate) and any remaining debt is written off —
    /// debt and collateral always reach zero together, never
    /// debt-with-no-collateral.
    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        Position storage pos = positions[user];
        uint256 debt = _accrue(pos);
        if (debt == 0) revert NothingToLiquidate();
        uint256 hf = healthFactor(user);
        if (hf >= WAD) revert PositionHealthy();
        if (repayAmount > debt) repayAmount = debt;

        // Severity-scaled bonus, not a flat rate: a position deep enough
        // underwater to risk becoming bad debt pays up to
        // `liquidationBonusMaxBps`, while one only just barely liquidatable
        // pays close to the `liquidationBonusBps` floor -- see
        // `_dynamicLiquidationBonusBps`.
        uint256 bonusBps = _dynamicLiquidationBonusBps(hf);

        uint256 collateralPrice18 = oracle.getPriceUsd18(address(collateralAsset));
        uint256 borrowPrice18 = oracle.getPriceUsd18(address(borrowAsset));

        uint256 repayValueUsd = _usdValue(repayAmount, borrowDecimals, borrowPrice18);
        uint256 seizeValueUsd = (repayValueUsd * (BPS_DENOMINATOR + bonusBps)) / BPS_DENOMINATOR;
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
            uint256 coveredValueUsd = (seizedValueUsd * BPS_DENOMINATOR) / (BPS_DENOMINATOR + bonusBps);
            uint256 coveredRepay = (coveredValueUsd * (10 ** borrowDecimals)) / borrowPrice18;
            if (coveredRepay < repayAmount) repayAmount = coveredRepay;
            badDebt = debt - repayAmount;
        }

        uint256 newDebt = debt - repayAmount - badDebt;
        totalDebtPrincipal = totalDebtPrincipal - debt + newDebt;
        debtTimeWeightedSum = debtTimeWeightedSum - (debt * block.timestamp) + (newDebt * block.timestamp);
        pos.debtPrincipal = uint128(newDebt);
        pos.collateral -= uint128(seizeCollateral);
        totalCollateral -= seizeCollateral;

        if (repayAmount > 0) borrowAsset.safeTransferFrom(msg.sender, address(this), repayAmount);
        if (seizeCollateral > 0) collateralAsset.safeTransfer(msg.sender, seizeCollateral);

        if (badDebt > 0 && protocolReserves > 0) {
            // badDebt just shrank totalDebtPrincipal -- the vault's real
            // backing -- without touching protocolReserves above. Left
            // unclamped, a write-off large enough (up to and including a
            // position's entire debt, same as this branch always is) can
            // push protocolReserves above what totalDebtPrincipal + the
            // vault's idle borrowAsset balance can actually back, which
            // makes every future totalAssets() call (and therefore every
            // deposit()/withdraw()) underflow-revert forever -- permanently
            // freezing every lender's funds, with no recovery path since
            // withdrawReserves() itself needs idle liquidity that may never
            // materialize. Clamp reserves down to what the vault can still
            // actually back the moment bad debt removes that backing,
            // taking the shortfall out of realized-but-unwithdrawn protocol
            // revenue instead of bricking the entire lending side of the
            // vault. See test_liquidate_fullBadDebtWriteOff_doesNotBrickTotalAssets.
            uint256 backing = totalDebtPrincipal + borrowAsset.balanceOf(address(this));
            if (protocolReserves > backing) {
                uint256 reservesWrittenOff = protocolReserves - backing;
                protocolReserves = backing;
                emit ProtocolReservesWrittenOff(reservesWrittenOff);
            }
        }

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
