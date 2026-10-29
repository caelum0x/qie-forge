// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {QieForgeVault} from "../src/vault/QieForgeVault.sol";
import {QieOracleAdapter} from "../src/oracle/QieOracleAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract QieForgeVaultTest is Test {
    QieForgeVault vault;
    QieOracleAdapter oracle;
    MockERC20 collateral; // WQIE stand-in, 18 decimals
    MockERC20 borrowToken; // TUSD stand-in, 6 decimals
    MockAggregatorV3 collateralFeed;
    MockAggregatorV3 borrowFeed;

    address borrower = address(0xB0770E7);
    address liquidator = address(0x1101DA7012);

    uint256 constant LTV_BPS = 7_500;
    uint256 constant LIQ_THRESHOLD_BPS = 8_000;
    uint256 constant LIQ_BONUS_BPS = 500;
    uint256 constant LIQ_BONUS_MAX_BPS_FLAT = 500; // == LIQ_BONUS_BPS -- curve disabled, exact pre-existing flat behavior
    uint256 constant RATE_PER_SECOND_18 = 1_585_489_599; // ≈ 5% APR
    uint256 constant BPS_DENOMINATOR = 10_000;
    address constant TREASURY = address(0x7EA5027);
    uint256 constant ZERO_RESERVE_FACTOR_BPS = 0;

    function setUp() public {
        collateral = new MockERC20("Wrapped QIE", "WQIE", 18);
        borrowToken = new MockERC20("Test USD", "TUSD", 6);

        collateralFeed = new MockAggregatorV3(8, "QIE / USD", 1_00_000_000); // $1.00
        borrowFeed = new MockAggregatorV3(8, "TUSD / USD", 1_00_000_000); // $1.00

        oracle = new QieOracleAdapter(address(this), 1 days);
        oracle.setFeed(address(collateral), address(collateralFeed));
        oracle.setFeed(address(borrowToken), address(borrowFeed));

        vault = new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );

        collateral.mint(borrower, 10_000e18);
        borrowToken.mint(address(vault), 1_000_000e6); // vault needs liquidity to lend out
        borrowToken.mint(liquidator, 1_000_000e6);

        vm.prank(borrower);
        collateral.approve(address(vault), type(uint256).max);
    }

    function test_depositAndBorrow_withinLtv_succeeds() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6); // 70% of $1000 collateral value, under 75% LTV
        vm.stopPrank();

        assertEq(borrowToken.balanceOf(borrower), 700e6);
        assertEq(vault.currentDebt(borrower), 700e6);
    }

    function test_borrow_exceedingLtv_reverts() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vm.expectRevert(QieForgeVault.ExceedsLtv.selector);
        vault.borrow(800e6); // 80% exceeds the 75% LTV cap
        vm.stopPrank();
    }

    function test_withdraw_belowLtvThreshold_reverts() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.expectRevert(QieForgeVault.ExceedsLtv.selector);
        vault.withdrawCollateral(500e18); // would leave 500 collateral backing 700 debt = 140% > 75% LTV cap
        vm.stopPrank();
    }

    function test_healthFactor_above1WhenSafe() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        uint256 hf = vault.healthFactor(borrower);
        // (1000 * 0.80) / 700 ≈ 1.142857
        assertApproxEqRel(hf, 1_142_857_142_857_142_857, 1e12);
    }

    function test_interest_accruesOverTime() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        uint256 debtBefore = vault.currentDebt(borrower);
        vm.warp(block.timestamp + 365 days);
        uint256 debtAfter = vault.currentDebt(borrower);

        assertGt(debtAfter, debtBefore);
        // ~5% APR on 700e6 over 1 year ≈ 35e6 extra debt.
        assertApproxEqRel(debtAfter - debtBefore, 35e6, 2e16);
    }

    /// @notice `healthFactor()` is a view function with no state mutation,
    /// so it must compute debt the same interest-inclusive way
    /// `currentDebt()` does -- using the raw, stale `pos.debtPrincipal`
    /// instead (the pre-fix behavior) makes a position whose interest has
    /// accrued for a long time without any borrow/repay/liquidate call
    /// *look* healthier than it really is to any external caller (the
    /// frontend's own `/vault` health-factor display, or a liquidator bot
    /// deciding whether a position is worth liquidating), delaying real
    /// liquidations and letting bad debt accumulate silently.
    function test_healthFactor_reflectsAccruedInterest_notJustStalePrincipal() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        // No interaction for a while -- pos.lastAccrual is stale. Kept
        // under the oracle's 1-day staleness window (set in setUp) so this
        // test isolates the healthFactor-vs-currentDebt discrepancy instead
        // of also tripping StalePrice.
        vm.warp(block.timestamp + 12 hours);

        uint256 accruedDebt = vault.currentDebt(borrower); // known-correct, interest-inclusive
        assertGt(accruedDebt, 700e6, "sanity: interest should have accrued");

        // healthFactor() must be computed against that same accrued debt,
        // i.e. HF == (collateralValueUsd * liqThresholdBps) / (accruedDebtValueUsd * BPS_DENOMINATOR).
        // Collateral/borrow price are both $1.00 here (18/6 decimals), so
        // USD value reduces to a straight unit comparison.
        uint256 expectedHf = (1_000e18 * LIQ_THRESHOLD_BPS * 1e18) / (accruedDebt * 1e12 * BPS_DENOMINATOR);
        assertApproxEqRel(vault.healthFactor(borrower), expectedHf, 1e9, "healthFactor must include accrued interest");
    }

    function test_liquidation_revertsWhenPositionHealthy() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        vm.startPrank(liquidator);
        borrowToken.approve(address(vault), 100e6);
        vm.expectRevert(QieForgeVault.PositionHealthy.selector);
        vault.liquidate(borrower, 100e6);
        vm.stopPrank();
    }

    function test_liquidation_succeedsWhenUnderwater_andPaysBonus() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        // Collateral price crashes from $1.00 to $0.50 -> HF drops below 1.
        collateralFeed.setAnswer(50_000_000);
        assertLt(vault.healthFactor(borrower), 1e18);

        uint256 liquidatorCollateralBefore = collateral.balanceOf(liquidator);

        vm.startPrank(liquidator);
        borrowToken.approve(address(vault), 100e6);
        vault.liquidate(borrower, 100e6);
        vm.stopPrank();

        uint256 seized = collateral.balanceOf(liquidator) - liquidatorCollateralBefore;
        // $100 repaid * 1.05 bonus / $0.50 price = 210 WQIE seized.
        assertApproxEqAbs(seized, 210e18, 1e15);
        assertEq(vault.currentDebt(borrower), 600e6);
    }

    function test_liquidation_revertsOnZeroDebt() public {
        vm.prank(borrower);
        vault.depositCollateral(1_000e18);

        vm.startPrank(liquidator);
        borrowToken.approve(address(vault), 1e6);
        vm.expectRevert(QieForgeVault.NothingToLiquidate.selector);
        vault.liquidate(borrower, 1e6);
        vm.stopPrank();
    }

    function test_repay_exceedingDebt_reverts() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        borrowToken_mintTo(borrower, 1e6); // give borrower enough to even attempt an over-repay
        vm.expectRevert(QieForgeVault.RepayExceedsDebt.selector);
        vault.repay(701e6);
        vm.stopPrank();
    }

    function borrowToken_mintTo(address to, uint256 amount) internal {
        borrowToken.mint(to, amount);
    }

    function test_partialLiquidation_canRestoreHealthAboveOne() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        // Mild price drop — unhealthy, but a partial liquidation can fix it.
        collateralFeed.setAnswer(80_000_000); // $0.80
        assertLt(vault.healthFactor(borrower), 1e18);

        vm.startPrank(liquidator);
        borrowToken.approve(address(vault), 400e6);
        vault.liquidate(borrower, 400e6);
        vm.stopPrank();

        assertEq(vault.currentDebt(borrower), 300e6);
        assertGt(vault.healthFactor(borrower), 1e18);
    }

    function test_sequentialLiquidators_eachGetProportionalBonus() public {
        address liquidator2 = address(0x1102);
        borrowToken.mint(liquidator2, 1_000_000e6);

        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        collateralFeed.setAnswer(50_000_000); // $0.50, deeply underwater

        vm.startPrank(liquidator);
        borrowToken.approve(address(vault), 50e6);
        vault.liquidate(borrower, 50e6);
        vm.stopPrank();
        uint256 firstSeized = collateral.balanceOf(liquidator);
        assertApproxEqAbs(firstSeized, 105e18, 1e15); // $50 * 1.05 / $0.50

        vm.startPrank(liquidator2);
        borrowToken.approve(address(vault), 50e6);
        vault.liquidate(borrower, 50e6);
        vm.stopPrank();
        uint256 secondSeized = collateral.balanceOf(liquidator2);
        assertApproxEqAbs(secondSeized, 105e18, 1e15);

        assertEq(vault.currentDebt(borrower), 600e6);
    }

    function test_liquidation_cannotSeizeMoreThanAvailableCollateral() public {
        vm.startPrank(borrower);
        vault.depositCollateral(100e18); // small collateral
        vault.borrow(70e6);
        vm.stopPrank();

        // Crash the price hard enough that even seizing 100% of collateral is still less than the bonus-adjusted value.
        collateralFeed.setAnswer(1_000_000); // $0.01
        assertLt(vault.healthFactor(borrower), 1e18);

        vm.startPrank(liquidator);
        borrowToken.approve(address(vault), 70e6);
        vault.liquidate(borrower, 70e6);
        vm.stopPrank();

        (uint128 remainingCollateral,,) = vault.positions(borrower);
        assertEq(remainingCollateral, 0);
    }

    function test_liquidation_minimalRepayStillZeroesDebt_whenCollateralExhausted() public {
        // Reproduces the real vulnerability found 2026-10-27 (KupiaSec report,
        // independently verified): a liquidator deliberately choosing a tiny
        // repayAmount while collateral is fully exhausted used to leave
        // phantom, permanently-unbacked debt on a position with zero
        // collateral. The fix caps the actual repay down to what the seized
        // collateral covers and writes off the rest — debt and collateral
        // must always reach zero together.
        vm.startPrank(borrower);
        vault.depositCollateral(100e18);
        vault.borrow(70e6);
        vm.stopPrank();

        collateralFeed.setAnswer(1_000_000); // $0.01 — deep crash
        assertLt(vault.healthFactor(borrower), 1e18);

        vm.startPrank(liquidator);
        borrowToken.approve(address(vault), 1e6);
        vault.liquidate(borrower, 1e6); // attacker requests a tiny repay on purpose
        vm.stopPrank();

        (uint128 remainingCollateral, uint128 remainingDebt,) = vault.positions(borrower);
        assertEq(remainingCollateral, 0);
        assertEq(remainingDebt, 0, "debt must be written off, not left phantom with zero collateral");
        assertEq(vault.currentDebt(borrower), 0);
    }

    function test_deposit_mintsSharesAtExchangeRate() public {
        // `vault` (from setUp) was pre-funded with 1_000_000e6 TUSD via a
        // direct mint, not deposit() -- same "ops-seeded liquidity" shape
        // as DeployDemo.s.sol -- so the first-ever deposit() call here must
        // take the MINIMUM_LENDER_SHARES-floor branch, not a naive 1:1
        // mint. See test_deposit_firstDepositor_cannotDrainPreFundedLiquidity
        // for why that distinction is a real security property, not just
        // an implementation detail.
        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);

        vm.startPrank(lender);
        borrowToken.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1_000e6);
        vm.stopPrank();

        // amount(1_000e6) : assetsBefore(1_000_000e6) == shares : MINIMUM_LENDER_SHARES(1000)
        // => shares == 1, and MINIMUM_LENDER_SHARES is locked to nobody.
        assertEq(shares, 1);
        assertEq(vault.lenderShares(lender), 1);
        assertEq(vault.totalLenderShares(), vault.MINIMUM_LENDER_SHARES() + 1);

        // Fairness check: that 1 share must still be worth exactly what the
        // lender put in, not inflated and not diluted.
        uint256 value = (vault.lenderShares(lender) * vault.totalAssets()) / vault.totalLenderShares();
        assertEq(value, 1_000e6);
    }

    function test_deposit_freshVault_firstDepositorStillMints1to1() public {
        // A genuinely pristine vault (assetsBefore == 0, same as before this
        // fix) must keep minting 1:1 -- the MINIMUM_LENDER_SHARES floor
        // only matters once there is pre-existing value to wall off.
        QieForgeVault freshVault = new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );
        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);

        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        uint256 shares = freshVault.deposit(1_000e6);
        vm.stopPrank();

        assertEq(shares, 1_000e6);
        assertEq(freshVault.totalLenderShares(), 1_000e6);
    }

    /// @notice Reproduces the real exploit found 2026-10-28 against this
    /// repo's own pre-fix bytecode (self-hosted QIE Forge demo deployment,
    /// see plans/qie-hackathon.md): a vault pre-funded with idle liquidity
    /// before anyone ever calls deposit() let the FIRST depositor mint
    /// shares against their own `amount` alone, ignoring the pre-existing
    /// balance entirely -- so they could deposit a small amount and
    /// immediately withdraw() nearly the ENTIRE pre-funded balance. Asserts
    /// the fix: the depositor can never redeem meaningfully more than what
    /// they actually put in, and the pre-funded balance survives.
    function test_deposit_firstDepositor_cannotDrainPreFundedLiquidity() public {
        // `vault` was pre-funded with 1_000_000e6 TUSD directly in setUp,
        // and nobody has called deposit() on it yet in this test.
        assertEq(vault.totalLenderShares(), 0);
        uint256 preFundedBalance = borrowToken.balanceOf(address(vault));
        assertEq(preFundedBalance, 1_000_000e6);

        address attacker = address(0xBAD1E4DE2);
        borrowToken.mint(attacker, 1_000e6);

        vm.startPrank(attacker);
        borrowToken.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1_000e6);

        uint256 balBefore = borrowToken.balanceOf(attacker);
        uint256 redeemed = vault.withdraw(shares);
        vm.stopPrank();

        // Pre-fix this would have returned ~1_000_000e6 (the whole
        // pre-funded balance) for a 1_000e6 deposit. Post-fix it must be
        // bounded to roughly what the attacker actually deposited (allow a
        // small rounding slack, never an order-of-magnitude windfall).
        assertEq(redeemed, borrowToken.balanceOf(attacker) - balBefore);
        assertLe(redeemed, 1_000e6 + 1, "first depositor must not be able to redeem more than they deposited");
        assertGe(
            borrowToken.balanceOf(address(vault)),
            preFundedBalance - 1,
            "pre-funded liquidity must survive an attacker's deposit+withdraw round trip"
        );
    }

    function test_withdraw_redeemsSharesForUnderlying() public {
        // Fresh vault, no donated liquidity — so this lender's shares are
        // the only claim on totalAssets() and should round-trip exactly.
        QieForgeVault freshVault = new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );
        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);

        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        uint256 shares = freshVault.deposit(1_000e6);
        uint256 balBefore = borrowToken.balanceOf(lender);
        uint256 amount = freshVault.withdraw(shares);
        vm.stopPrank();

        assertEq(amount, 1_000e6);
        assertEq(borrowToken.balanceOf(lender) - balBefore, 1_000e6);
        assertEq(freshVault.lenderShares(lender), 0);
        assertEq(freshVault.totalLenderShares(), 0);
    }

    function test_withdraw_revertsWhenSharesExceedBalance() public {
        QieForgeVault freshVault = new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );
        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);

        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        uint256 shares = freshVault.deposit(1_000e6);
        vm.expectRevert(QieForgeVault.InsufficientShares.selector);
        freshVault.withdraw(shares + 1);
        vm.stopPrank();
    }

    function test_withdraw_revertsWhenLiquidityIsLentOut() public {
        // A fresh vault with no pre-funded "donated" liquidity — only
        // lender-supplied capital — so a borrow() actually drains the idle
        // balance a lender would try to withdraw against.
        QieForgeVault freshVault = new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );

        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);
        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        uint256 shares = freshVault.deposit(1_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateral.approve(address(freshVault), type(uint256).max);
        freshVault.depositCollateral(2_000e18);
        freshVault.borrow(900e6); // drains all but 100e6 of idle liquidity
        vm.stopPrank();

        vm.startPrank(lender);
        vm.expectRevert(QieForgeVault.InsufficientLiquidity.selector);
        freshVault.withdraw(shares); // needs the full 1,000e6, only 100e6 idle
        vm.stopPrank();
    }

    function test_deposit_lenderSharesAppreciateFromBorrowerInterest() public {
        QieForgeVault freshVault = new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );

        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);
        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        uint256 shares = freshVault.deposit(1_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateral.approve(address(freshVault), type(uint256).max);
        freshVault.depositCollateral(1_000e18);
        freshVault.borrow(700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 owed = freshVault.currentDebt(borrower);
        assertGt(owed, 700e6); // interest accrued

        vm.startPrank(borrower);
        borrowToken.mint(borrower, owed);
        borrowToken.approve(address(freshVault), owed);
        freshVault.repay(owed); // fully repay, including interest, refilling idle liquidity
        vm.stopPrank();

        vm.prank(lender);
        uint256 amount = freshVault.withdraw(shares);
        assertGt(amount, 1_000e6, "lender's shares must be worth more than their deposit after interest accrued");
    }

    /// @notice Regression for the lender-pricing blind spot fixed alongside
    /// this test (same root cause as the healthFactor() staleness fix, but
    /// for totalAssets()/deposit()/withdraw() instead of the health-factor
    /// display): without the debtTimeWeightedSum accrual identity,
    /// totalAssets() == idle balance + totalDebtPrincipal, and
    /// totalDebtPrincipal only updates when a specific position is touched
    /// (borrow/repay/liquidate). A big position left untouched accrues real
    /// interest that totalAssets() couldn't see at all, understating the
    /// vault's true value to every depositor/withdrawer in the meantime.
    function test_totalAssets_includesPendingInterest_fromUntouchedPosition() public {
        QieForgeVault freshVault = new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );

        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);
        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        freshVault.deposit(1_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateral.approve(address(freshVault), type(uint256).max);
        freshVault.depositCollateral(1_000e18);
        freshVault.borrow(700e6);
        vm.stopPrank();

        uint256 idle = borrowToken.balanceOf(address(freshVault));
        uint256 staleSum = idle + freshVault.totalDebtPrincipal(); // the pre-fix totalAssets() value

        vm.warp(block.timestamp + 180 days);

        uint256 trueDebt = freshVault.currentDebt(borrower); // known-correct, interest-inclusive
        assertGt(trueDebt, 700e6, "sanity: interest should have accrued");

        uint256 reportedAssets = freshVault.totalAssets();
        assertGt(
            reportedAssets, staleSum, "totalAssets() must grow from accrued interest even without touching the position"
        );
        assertApproxEqRel(
            reportedAssets, idle + trueDebt, 1e9, "totalAssets() must match the true interest-inclusive debt"
        );
    }

    /// @notice Proves the fix changes real deposit()/withdraw() pricing, not
    /// just a view getter: a second lender arriving while a large position's
    /// interest sits un-accrued must be priced against the real,
    /// interest-inclusive totalAssets() -- not the stale sum -- so they
    /// cannot ride in on interest that rightfully belongs to the lender who
    /// was already supplying capital the whole time.
    function test_deposit_pricedFairly_despiteUntouchedAccruingPosition() public {
        QieForgeVault freshVault = new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );

        address lender1 = address(0x1E4DE2);
        borrowToken.mint(lender1, 1_000e6);
        vm.startPrank(lender1);
        borrowToken.approve(address(freshVault), 1_000e6);
        uint256 shares1 = freshVault.deposit(1_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateral.approve(address(freshVault), type(uint256).max);
        freshVault.depositCollateral(1_000e18);
        freshVault.borrow(700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 180 days);

        uint256 staleAssets = borrowToken.balanceOf(address(freshVault)) + freshVault.totalDebtPrincipal();

        address lender2 = address(0xBAD2);
        borrowToken.mint(lender2, 100e6);
        vm.startPrank(lender2);
        borrowToken.approve(address(freshVault), 100e6);
        uint256 shares2 = freshVault.deposit(100e6);
        vm.stopPrank();

        // Pre-fix, deposit() priced lender2 off `staleAssets` (minting
        // amount*totalLenderShares/staleAssets shares -- more shares than
        // fair, since staleAssets understates the vault's real value).
        uint256 staleShares = (100e6 * shares1) / staleAssets;
        assertLt(shares2, staleShares, "post-fix deposit must mint fewer shares than the stale pre-fix pricing would");

        // Force the real accrual now (the borrower repays in full) and
        // confirm lender2 cannot redeem more than they actually deposited --
        // the interest that accrued before lender2 arrived must stay with
        // lender1, not leak to the newcomer.
        uint256 owed = freshVault.currentDebt(borrower);
        vm.startPrank(borrower);
        borrowToken.mint(borrower, owed);
        borrowToken.approve(address(freshVault), owed);
        freshVault.repay(owed);
        vm.stopPrank();

        vm.prank(lender2);
        uint256 redeemed2 = freshVault.withdraw(shares2);
        assertLe(
            redeemed2, 100e6 + 1, "a same-window depositor must not capture interest that accrued before they deposited"
        );
    }

    // ---------------------------------------------------------------- //
    // Reserve factor (protocol revenue capture)
    // ---------------------------------------------------------------- //

    uint256 constant RESERVE_FACTOR_BPS = 1_000; // 10%

    function _newVaultWithReserveFactor() internal returns (QieForgeVault) {
        return new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            TREASURY,
            RESERVE_FACTOR_BPS
        );
    }

    function test_constructor_revertsOnReserveFactorAboveOneHundredPercent() public {
        vm.expectRevert(QieForgeVault.InvalidReserveFactor.selector);
        new QieForgeVault(
            collateral, borrowToken, oracle, LTV_BPS, LIQ_THRESHOLD_BPS, LIQ_BONUS_BPS, LIQ_BONUS_MAX_BPS_FLAT, RATE_PER_SECOND_18, TREASURY, 10_001
        );
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(QieForgeVault.ZeroTreasury.selector);
        new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_FLAT,
            RATE_PER_SECOND_18,
            address(0),
            ZERO_RESERVE_FACTOR_BPS
        );
    }

    /// @notice A real reserveFactorBps=10% must mean lenders only ever earn
    /// 90% of a borrower's accrued interest -- the other 10% becomes
    /// withdrawable protocol revenue -- without changing how much the
    /// borrower actually owes.
    function test_reserveFactor_splitsInterestBetweenLenderAndTreasury() public {
        QieForgeVault freshVault = _newVaultWithReserveFactor();

        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);
        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        uint256 shares = freshVault.deposit(1_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateral.approve(address(freshVault), type(uint256).max);
        freshVault.depositCollateral(1_000e18);
        freshVault.borrow(700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 owed = freshVault.currentDebt(borrower);
        uint256 interest = owed - 700e6;
        assertGt(interest, 0, "sanity: interest accrued");

        vm.startPrank(borrower);
        borrowToken.mint(borrower, owed);
        borrowToken.approve(address(freshVault), owed);
        freshVault.repay(owed); // realizes the accrual -> protocolReserves updates
        vm.stopPrank();

        // Borrower owed the full, un-skimmed interest -- the split only
        // affects who the repaid interest ends up belonging to.
        assertEq(freshVault.protocolReserves(), (interest * RESERVE_FACTOR_BPS) / BPS_DENOMINATOR);

        vm.prank(lender);
        uint256 amount = freshVault.withdraw(shares);
        uint256 lenderInterest = amount - 1_000e6;
        assertApproxEqAbs(
            lenderInterest,
            interest - (interest * RESERVE_FACTOR_BPS) / BPS_DENOMINATOR,
            1,
            "lender must only receive interest net of the reserve-factor cut"
        );
    }

    /// @notice Mirrors test_totalAssets_includesPendingInterest_fromUntouchedPosition
    /// for the reserve side: totalReserves() must count the protocol's cut
    /// of interest that is economically accrued but not yet realized into
    /// `protocolReserves` via a real per-position touch -- otherwise a
    /// lender depositing during that stale window would be priced as if the
    /// reserve cut didn't exist yet, re-opening the same windfall
    /// `debtTimeWeightedSum` was added to close for lenders generally.
    function test_totalReserves_includesPendingCut_fromUntouchedPosition() public {
        QieForgeVault freshVault = _newVaultWithReserveFactor();

        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);
        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        freshVault.deposit(1_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateral.approve(address(freshVault), type(uint256).max);
        freshVault.depositCollateral(1_000e18);
        freshVault.borrow(700e6);
        vm.stopPrank();

        assertEq(freshVault.protocolReserves(), 0, "no interest has accrued yet");
        assertEq(freshVault.totalReserves(), 0);

        vm.warp(block.timestamp + 365 days);

        // Position never touched again -- protocolReserves is still 0 (lazy
        // realization), but totalReserves() must already report the real
        // pending cut so totalAssets()/deposit()/withdraw() price correctly
        // without needing anyone to touch the stale position first.
        assertEq(freshVault.protocolReserves(), 0, "realized reserves stay 0 until a real touch happens");
        uint256 trueInterest = freshVault.currentDebt(borrower) - 700e6;
        uint256 expectedPendingReserve = (trueInterest * RESERVE_FACTOR_BPS) / BPS_DENOMINATOR;
        assertApproxEqRel(
            freshVault.totalReserves(),
            expectedPendingReserve,
            1e9,
            "totalReserves() must already reflect the pending, not-yet-realized reserve cut"
        );
    }

    function test_withdrawReserves_onlyTreasuryCanWithdraw_andOnlyRealizedAmount() public {
        QieForgeVault freshVault = _newVaultWithReserveFactor();

        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);
        vm.startPrank(lender);
        borrowToken.approve(address(freshVault), 1_000e6);
        freshVault.deposit(1_000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        collateral.approve(address(freshVault), type(uint256).max);
        freshVault.depositCollateral(1_000e18);
        freshVault.borrow(700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        uint256 owed = freshVault.currentDebt(borrower);
        vm.startPrank(borrower);
        borrowToken.mint(borrower, owed);
        borrowToken.approve(address(freshVault), owed);
        freshVault.repay(owed);
        vm.stopPrank();

        uint256 realized = freshVault.protocolReserves();
        assertGt(realized, 0, "sanity: real interest was realized into protocolReserves via repay()");

        // Not the treasury -- reverts.
        vm.prank(borrower);
        vm.expectRevert(QieForgeVault.NotTreasury.selector);
        freshVault.withdrawReserves(1);

        // Treasury cannot withdraw more than what's actually realized.
        vm.prank(TREASURY);
        vm.expectRevert(QieForgeVault.InsufficientReserves.selector);
        freshVault.withdrawReserves(realized + 1);

        // Real withdrawal moves exactly `realized` borrowAsset to treasury
        // and zeroes protocolReserves.
        uint256 treasuryBalBefore = borrowToken.balanceOf(TREASURY);
        vm.prank(TREASURY);
        freshVault.withdrawReserves(realized);
        assertEq(borrowToken.balanceOf(TREASURY) - treasuryBalBefore, realized);
        assertEq(freshVault.protocolReserves(), 0);
    }

    /// @notice A 0% reserve factor (the default used throughout the rest of
    /// this suite) must be fully backward-compatible: lenders get 100% of
    /// interest, exactly as before this feature existed.
    function test_zeroReserveFactor_lendersKeepAllInterest() public view {
        assertEq(vault.reserveFactorBps(), 0);
        assertEq(vault.protocolReserves(), 0);
        assertEq(vault.totalReserves(), 0);
    }

    // ---------------------------------------------------------------- //
    // Liquidation incentive curve (severity-scaled liquidation bonus)
    // ---------------------------------------------------------------- //

    uint256 constant LIQ_BONUS_MAX_BPS_CURVE = 2_000; // 20% once deeply underwater

    function _newVaultWithLiquidationCurve() internal returns (QieForgeVault) {
        return new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_MAX_BPS_CURVE,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );
    }

    function test_constructor_revertsOnLiquidationBonusMaxBelowBase() public {
        vm.expectRevert(QieForgeVault.InvalidLiquidationBonusCurve.selector);
        new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            LIQ_BONUS_BPS - 1, // max below base -- malformed curve
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );
    }

    function test_constructor_revertsOnLiquidationBonusMaxAboveOneHundredPercent() public {
        vm.expectRevert(QieForgeVault.InvalidLiquidationBonusCurve.selector);
        new QieForgeVault(
            collateral,
            borrowToken,
            oracle,
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            BPS_DENOMINATOR + 1,
            RATE_PER_SECOND_18,
            TREASURY,
            ZERO_RESERVE_FACTOR_BPS
        );
    }

    /// @notice `vault` (from setUp) sets liquidationBonusMaxBps ==
    /// liquidationBonusBps -- the explicit "curve disabled" configuration.
    /// Regardless of how underwater a position gets, the bonus must stay
    /// pinned to the flat base rate, exactly the behavior every other
    /// liquidation test in this file (all written before this feature
    /// existed) already assumes and asserts numerically.
    function test_liquidationBonus_isFlat_whenMaxEqualsBase() public {
        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        collateralFeed.setAnswer(80_000_000); // $0.80 -- mildly underwater
        assertEq(vault.liquidationBonusBpsFor(borrower), LIQ_BONUS_BPS);

        collateralFeed.setAnswer(1_000_000); // $0.01 -- deeply underwater
        assertEq(vault.liquidationBonusBpsFor(borrower), LIQ_BONUS_BPS);
    }

    /// @notice A healthy position (or one with no debt at all) has nothing
    /// to liquidate, so `liquidationBonusBpsFor` reports the flat base rate
    /// rather than reverting -- a risk dashboard polling this for every
    /// position should always get a number back.
    function test_liquidationBonusBpsFor_returnsBaseBonus_whenNotLiquidatable() public {
        assertEq(vault.liquidationBonusBpsFor(borrower), LIQ_BONUS_BPS, "no position at all");

        vm.startPrank(borrower);
        vault.depositCollateral(1_000e18);
        vault.borrow(700e6);
        vm.stopPrank();

        assertEq(vault.liquidationBonusBpsFor(borrower), LIQ_BONUS_BPS, "healthy position");
    }

    /// @notice The real gap this feature closes: before it, a liquidator
    /// had zero extra incentive to rush a severely underwater position
    /// (the one actually at risk of becoming unrecoverable bad debt) over
    /// a barely-underwater one -- both paid the exact same flat bonus. With
    /// the curve, a mildly underwater position pays close to the base
    /// rate, and a deeply underwater one (healthFactor <= 0.5, the curve's
    /// floor) pays the full `liquidationBonusMaxBps`, in between
    /// interpolated linearly. All three numbers below are exact, closed-
    /// form values derived from `_liquidationBonusBps`'s own formula (not
    /// approximations), so this also doubles as a regression test against
    /// the formula itself.
    function test_liquidationBonus_scalesWithSeverity_andActualLiquidateMatchesIt() public {
        QieForgeVault curveVault = _newVaultWithLiquidationCurve();

        borrowToken.mint(address(curveVault), 1_000_000e6);
        vm.startPrank(borrower);
        collateral.approve(address(curveVault), type(uint256).max);
        curveVault.depositCollateral(1_000e18);
        curveVault.borrow(700e6);
        vm.stopPrank();

        // Mildly underwater: healthFactor == 32/35 ≈ 0.9143, well above the
        // 0.5 curve floor -- bonus must sit strictly between the base and
        // max, not already be clamped to either end.
        collateralFeed.setAnswer(80_000_000); // $0.80
        uint256 mildHf = curveVault.healthFactor(borrower);
        assertLt(mildHf, 1e18);
        assertGt(mildHf, 5e17);
        uint256 mildBonus = curveVault.liquidationBonusBpsFor(borrower);
        assertEq(mildBonus, 757, "exact closed-form interpolation at hf=32/35");
        assertGt(mildBonus, LIQ_BONUS_BPS);
        assertLt(mildBonus, LIQ_BONUS_MAX_BPS_CURVE);

        // Deeply underwater: healthFactor == 12/35 ≈ 0.3429, at/below the
        // 0.5 floor -- bonus must be clamped to exactly the max, not
        // extrapolated past it.
        collateralFeed.setAnswer(30_000_000); // $0.30
        uint256 severeHf = curveVault.healthFactor(borrower);
        assertLe(severeHf, 5e17);
        uint256 severeBonus = curveVault.liquidationBonusBpsFor(borrower);
        assertEq(severeBonus, LIQ_BONUS_MAX_BPS_CURVE, "clamped to the max once at/below the floor");
        assertGt(severeBonus, mildBonus, "a more severely underwater position must pay a strictly higher bonus");

        // Real liquidate() at the severe price must seize exactly the
        // max-bonus-implied amount of collateral, not the flat base-bonus
        // amount a pre-fix vault would have paid for the same repay.
        uint256 liquidatorCollateralBefore = collateral.balanceOf(liquidator);
        vm.startPrank(liquidator);
        borrowToken.approve(address(curveVault), 100e6);
        curveVault.liquidate(borrower, 100e6);
        vm.stopPrank();

        uint256 seized = collateral.balanceOf(liquidator) - liquidatorCollateralBefore;
        // $100 repaid * 1.20 (max bonus) / $0.30 price = 400 WQIE exactly.
        assertEq(seized, 400e18, "exact closed-form seize amount at the 20% max bonus");
        assertEq(curveVault.currentDebt(borrower), 600e6);
    }
}
