// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {QieOracleAdapter} from "../src/oracle/QieOracleAdapter.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract QieOracleAdapterTest is Test {
    QieOracleAdapter adapter;
    MockAggregatorV3 btcFeed;
    address asset = address(0xB7C);

    function setUp() public {
        adapter = new QieOracleAdapter(address(this), 1 hours);
        // Mirrors the REAL verified BTC oracle: decimals=8, description="BTC / USDT".
        btcFeed = new MockAggregatorV3(8, "BTC / USDT", 6_012_345_000_000); // $60,123.45
    }

    function test_revertsWhenNoFeedConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(QieOracleAdapter.NoFeedConfigured.selector, asset));
        adapter.getPriceUsd18(asset);
    }

    function test_normalizesRealBtcOracleDecimalsTo18() public {
        adapter.setFeed(asset, address(btcFeed));
        uint256 price18 = adapter.getPriceUsd18(asset);
        // 6_012_345_000_000 at 8 decimals == $60,123.45 -> 60123.45e18
        assertEq(price18, 60_123.45e18);
    }

    function test_revertsOnNonPositiveAnswer() public {
        adapter.setFeed(asset, address(btcFeed));
        btcFeed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(QieOracleAdapter.NonPositiveAnswer.selector, asset, int256(0)));
        adapter.getPriceUsd18(asset);
    }

    function test_revertsOnStalePrice() public {
        adapter.setFeed(asset, address(btcFeed));
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert();
        adapter.getPriceUsd18(asset);
    }

    function test_revertsWhenFeedDecimalsExceed18() public {
        MockAggregatorV3 badFeed = new MockAggregatorV3(20, "BAD / USD", 1);
        adapter.setFeed(asset, address(badFeed));
        vm.expectRevert(abi.encodeWithSelector(QieOracleAdapter.DecimalsTooLarge.selector, uint8(20)));
        adapter.getPriceUsd18(asset);
    }

    function test_feedCanBeRotatedToANewAggregator() public {
        adapter.setFeed(asset, address(btcFeed));
        assertEq(adapter.getPriceUsd18(asset), 60_123.45e18);

        MockAggregatorV3 newFeed = new MockAggregatorV3(8, "BTC / USDT v2", 61_000_00000000);
        adapter.setFeed(asset, address(newFeed));
        assertEq(adapter.getPriceUsd18(asset), 61_000e18);
    }

    function test_maxStalenessCanBeDisabledWithZero() public {
        adapter.setFeed(asset, address(btcFeed));
        adapter.setMaxStaleness(0);
        vm.warp(block.timestamp + 365 days);
        // Staleness check is skipped entirely when maxStaleness == 0.
        assertEq(adapter.getPriceUsd18(asset), 60_123.45e18);
    }

    function test_onlyOwnerCanSetFeed() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        adapter.setFeed(asset, address(btcFeed));
    }
}
