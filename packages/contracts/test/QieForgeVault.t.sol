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
    uint256 constant RATE_PER_SECOND_18 = 1_585_489_599; // ≈ 5% APR

    function setUp() public {
        collateral = new MockERC20("Wrapped QIE", "WQIE", 18);
        borrowToken = new MockERC20("Test USD", "TUSD", 6);

        collateralFeed = new MockAggregatorV3(8, "QIE / USD", 1_00_000_000); // $1.00
        borrowFeed = new MockAggregatorV3(8, "TUSD / USD", 1_00_000_000); // $1.00

        oracle = new QieOracleAdapter(address(this), 1 days);
        oracle.setFeed(address(collateral), address(collateralFeed));
        oracle.setFeed(address(borrowToken), address(borrowFeed));

        vault = new QieForgeVault(
            collateral, borrowToken, oracle, LTV_BPS, LIQ_THRESHOLD_BPS, LIQ_BONUS_BPS, RATE_PER_SECOND_18
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
        address lender = address(0x1E4DE2);
        borrowToken.mint(lender, 1_000e6);

        vm.startPrank(lender);
        borrowToken.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1_000e6);
        vm.stopPrank();

        assertEq(shares, 1_000e6); // first depositor mints 1:1
        assertEq(vault.lenderShares(lender), 1_000e6);
        assertEq(vault.totalLenderShares(), 1_000e6);
    }

    function test_withdraw_redeemsSharesForUnderlying() public {
        // Fresh vault, no donated liquidity — so this lender's shares are
        // the only claim on totalAssets() and should round-trip exactly.
        QieForgeVault freshVault = new QieForgeVault(
            collateral, borrowToken, oracle, LTV_BPS, LIQ_THRESHOLD_BPS, LIQ_BONUS_BPS, RATE_PER_SECOND_18
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
            collateral, borrowToken, oracle, LTV_BPS, LIQ_THRESHOLD_BPS, LIQ_BONUS_BPS, RATE_PER_SECOND_18
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
            collateral, borrowToken, oracle, LTV_BPS, LIQ_THRESHOLD_BPS, LIQ_BONUS_BPS, RATE_PER_SECOND_18
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
            collateral, borrowToken, oracle, LTV_BPS, LIQ_THRESHOLD_BPS, LIQ_BONUS_BPS, RATE_PER_SECOND_18
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
}
