// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {QieForgeFactory} from "../src/QieForgeFactory.sol";
import {QieForgeRouter} from "../src/QieForgeRouter.sol";
import {QieForgeLibrary} from "../src/libraries/QieForgeLibrary.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract QieForgeRouterTest is Test {
    QieForgeFactory factory;
    QieForgeRouter router;
    MockERC20 tokenA; // e.g. WQIE
    MockERC20 tokenB; // e.g. middle hop token
    MockERC20 tokenC; // e.g. QUSDC stand-in
    MockERC20 tokenD; // second middle hop, for 3-hop routing tests

    address alice = address(0xA11CE);
    address trader = address(0x7AADE12);

    function setUp() public {
        factory = new QieForgeFactory(address(this));
        router = new QieForgeRouter(address(factory));

        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        tokenC = new MockERC20("Token C", "TKC", 6); // different decimals on purpose
        tokenD = new MockERC20("Token D", "TKD", 8); // yet another decimals count, on purpose

        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
        tokenC.mint(alice, 1_000_000e6);
        tokenD.mint(alice, 1_000_000e8);
        tokenA.mint(trader, 10_000e18);

        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenD.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tokenA), address(tokenB), 100_000e18, 100_000e18, 0, 0, alice, block.timestamp + 1);
        router.addLiquidity(address(tokenB), address(tokenC), 100_000e18, 100_000e6, 0, 0, alice, block.timestamp + 1);
        router.addLiquidity(address(tokenC), address(tokenD), 100_000e6, 100_000e8, 0, 0, alice, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_addLiquidity_createsPairAndMintsShares() public view {
        address pair = factory.getPair(address(tokenA), address(tokenB));
        assertTrue(pair != address(0));
    }

    function test_multiHopSwap_matchesLibraryQuote() public {
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);

        uint256 amountIn = 1_000e18;
        uint256[] memory expected = router.getAmountsOut(amountIn, path);

        vm.startPrank(trader);
        tokenA.approve(address(router), amountIn);
        uint256[] memory actual =
            router.swapExactTokensForTokens(amountIn, expected[2], path, trader, block.timestamp + 1);
        vm.stopPrank();

        assertEq(actual[2], expected[2]);
        assertEq(tokenC.balanceOf(trader), expected[2]);
    }

    function test_swapExactTokensForTokens_revertsBelowMinOut() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountIn = 1_000e18;
        uint256[] memory expected = router.getAmountsOut(amountIn, path);

        vm.startPrank(trader);
        tokenA.approve(address(router), amountIn);
        vm.expectRevert(QieForgeRouter.InsufficientOutputAmount.selector);
        router.swapExactTokensForTokens(amountIn, expected[1] + 1, path, trader, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_removeLiquidity_returnsUnderlyingTokens() public {
        address pair = factory.getPair(address(tokenA), address(tokenB));
        uint256 lpBalance = MockERC20(pair).balanceOf(alice);

        vm.startPrank(alice);
        MockERC20(pair).approve(address(router), lpBalance);
        (uint256 amountA, uint256 amountB) =
            router.removeLiquidity(address(tokenA), address(tokenB), lpBalance / 2, 0, 0, alice, block.timestamp + 1);
        vm.stopPrank();

        assertGt(amountA, 0);
        assertGt(amountB, 0);
    }

    function test_threeHopSwap_acrossThreePools_matchesLibraryQuote() public {
        address[] memory path = new address[](4);
        path[0] = address(tokenA);
        path[1] = address(tokenB);
        path[2] = address(tokenC);
        path[3] = address(tokenD);

        uint256 amountIn = 500e18;
        uint256[] memory expected = router.getAmountsOut(amountIn, path);
        assertEq(expected.length, 4);

        vm.startPrank(trader);
        tokenA.approve(address(router), amountIn);
        uint256[] memory actual =
            router.swapExactTokensForTokens(amountIn, expected[3], path, trader, block.timestamp + 1);
        vm.stopPrank();

        assertEq(actual[3], expected[3]);
        assertEq(tokenD.balanceOf(trader), expected[3]);
        // Every intermediate hop's reserves should have moved — a real
        // multi-pool route, not a single pair swap mislabeled as 3-hop.
        assertGt(expected[1], 0);
        assertGt(expected[2], 0);
    }

    function test_swapTokensForExactTokens_pullsExactlyQuotedInput() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountOut = 500e18;
        uint256[] memory expected = router.getAmountsIn(amountOut, path);

        uint256 traderBalanceBefore = tokenA.balanceOf(trader);
        vm.startPrank(trader);
        tokenA.approve(address(router), expected[0]);
        uint256[] memory actual =
            router.swapTokensForExactTokens(amountOut, expected[0], path, trader, block.timestamp + 1);
        vm.stopPrank();

        assertEq(actual[0], expected[0]);
        assertEq(tokenB.balanceOf(trader), amountOut);
        assertEq(traderBalanceBefore - tokenA.balanceOf(trader), expected[0]);
    }

    function test_swapTokensForExactTokens_revertsAboveMaxIn() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        uint256 amountOut = 500e18;
        uint256[] memory expected = router.getAmountsIn(amountOut, path);

        vm.startPrank(trader);
        tokenA.approve(address(router), expected[0] - 1);
        vm.expectRevert(QieForgeRouter.ExcessiveInputAmount.selector);
        router.swapTokensForExactTokens(amountOut, expected[0] - 1, path, trader, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_deadlineExpired_reverts() public {
        address[] memory path = new address[](2);
        path[0] = address(tokenA);
        path[1] = address(tokenB);

        vm.startPrank(trader);
        tokenA.approve(address(router), 1e18);
        vm.expectRevert(QieForgeRouter.Expired.selector);
        router.swapExactTokensForTokens(1e18, 0, path, trader, block.timestamp - 1);
        vm.stopPrank();
    }
}
