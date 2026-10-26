// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {QieForgeFactory} from "../src/QieForgeFactory.sol";
import {QieForgePair} from "../src/QieForgePair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract QieForgePairTest is Test {
    QieForgeFactory factory;
    MockERC20 tokenA;
    MockERC20 tokenB;
    QieForgePair pair;
    address token0;
    address token1;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        factory = new QieForgeFactory(address(this));
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        pair = QieForgePair(pairAddr);
        token0 = pair.token0();
        token1 = pair.token1();

        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
        tokenA.mint(bob, 1_000_000e18);
        tokenB.mint(bob, 1_000_000e18);
    }

    function _addLiquidity(address who, uint256 amount0, uint256 amount1) internal returns (uint256 liquidity) {
        vm.startPrank(who);
        MockERC20(token0).transfer(address(pair), amount0);
        MockERC20(token1).transfer(address(pair), amount1);
        liquidity = pair.mint(who);
        vm.stopPrank();
    }

    function test_firstMint_locksMinimumLiquidity() public {
        uint256 liquidity = _addLiquidity(alice, 1_000e18, 4_000e18);
        // sqrt(1000e18 * 4000e18) = sqrt(4_000_000) * 1e18 = 2000e18
        assertEq(liquidity, 2_000e18 - pair.MINIMUM_LIQUIDITY());
        assertEq(pair.balanceOf(address(0xdEaD)), pair.MINIMUM_LIQUIDITY());
        assertEq(pair.totalSupply(), 2_000e18);
    }

    function test_mint_proportionalOnSecondDeposit() public {
        _addLiquidity(alice, 1_000e18, 4_000e18);
        uint256 supplyBefore = pair.totalSupply();

        // Bob adds exactly 10% of reserves -> should get 10% of supply.
        uint256 liquidity = _addLiquidity(bob, 100e18, 400e18);
        assertApproxEqRel(liquidity, supplyBefore / 10, 1e12);
    }

    function test_swap_respectsConstantProductWithFee() public {
        _addLiquidity(alice, 10_000e18, 10_000e18);
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();

        uint256 amountIn = 100e18;
        vm.startPrank(bob);
        MockERC20(token0).transfer(address(pair), amountIn);
        // amountOut computed off-chain here using the same 30bps formula the router uses.
        uint256 amountInWithFee = amountIn * 9970;
        uint256 amountOut = (amountInWithFee * r1Before) / (uint256(r0Before) * 10_000 + amountInWithFee);
        pair.swap(0, amountOut, bob);
        vm.stopPrank();

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        // k must not decrease (fee makes it strictly increase).
        assertGe(uint256(r0After) * r1After, uint256(r0Before) * r1Before);
        assertEq(r0After, r0Before + amountIn);
        assertEq(r1After, r1Before - amountOut);
    }

    function test_swap_revertsIfInvariantViolated() public {
        _addLiquidity(alice, 10_000e18, 10_000e18);
        vm.startPrank(bob);
        MockERC20(token0).transfer(address(pair), 100e18);
        // Demanding way more output than the constant-product formula allows.
        vm.expectRevert(QieForgePair.KInvariant.selector);
        pair.swap(0, 500e18, bob);
        vm.stopPrank();
    }

    function test_burn_returnsProportionalShare() public {
        _addLiquidity(alice, 10_000e18, 10_000e18);
        uint256 lpBalance = pair.balanceOf(alice);

        vm.startPrank(alice);
        pair.transfer(address(pair), lpBalance / 2);
        (uint256 amount0, uint256 amount1) = pair.burn(alice);
        vm.stopPrank();

        assertApproxEqRel(amount0, 5_000e18, 1e12);
        assertApproxEqRel(amount1, 5_000e18, 1e12);
    }

    function test_priceCumulative_accumulatesOverTime() public {
        _addLiquidity(alice, 10_000e18, 20_000e18);
        uint256 before = pair.price0CumulativeLast();

        vm.warp(block.timestamp + 1 hours);
        pair.sync();

        uint256 after_ = pair.price0CumulativeLast();
        assertGt(after_, before);
    }

    function test_protocolFee_mintsToFeeToOnGrowth() public {
        factory.setFeeTo(address(0xFEE));
        _addLiquidity(alice, 10_000e18, 10_000e18);

        // Several swaps generate fee-driven k growth.
        for (uint256 i; i < 5; i++) {
            vm.startPrank(bob);
            MockERC20(token0).transfer(address(pair), 200e18);
            (uint112 r0,,) = pair.getReserves();
            uint256 amountInWithFee = 200e18 * 9970;
            (, uint112 r1,) = pair.getReserves();
            uint256 out = (amountInWithFee * r1) / (uint256(r0) * 10_000 + amountInWithFee);
            pair.swap(0, out, bob);
            vm.stopPrank();
        }

        // Triggers protocol fee mint via the next liquidity event.
        _addLiquidity(bob, 50e18, 50e18);
        assertGt(pair.balanceOf(address(0xFEE)), 0);
    }
}
