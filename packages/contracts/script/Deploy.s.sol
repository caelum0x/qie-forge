// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {QieForgeFactory} from "../src/QieForgeFactory.sol";
import {QieForgeRouter} from "../src/QieForgeRouter.sol";
import {QieOracleAdapter} from "../src/oracle/QieOracleAdapter.sol";

/// @notice Deploys the QIE Forge AMM core (factory + router) and a bare
/// QieOracleAdapter to either network.
///
/// Usage (testnet — no real funds needed beyond a tiny amount of testnet
/// QIE from the faucet for gas):
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url qie_testnet --broadcast --private-key $DEPLOYER_PRIVATE_KEY
///
/// This script intentionally does NOT wire QieOracleAdapter to QIE's real
/// oracle addresses by default — those are confirmed deployed on Mainnet
/// only (see packages/core/src/oracle.ts), so a Testnet deployment has
/// nothing real to point at yet. Call `adapter.setFeed(asset, feed)`
/// yourself after deployment once you know what you're pricing (a real
/// Mainnet oracle address, or a test MockAggregatorV3 you deploy
/// separately for a Testnet demo).
contract Deploy is Script {
    function run() external returns (QieForgeFactory factory, QieForgeRouter router, QieOracleAdapter adapter) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        uint256 maxStaleness = vm.envOr("ORACLE_MAX_STALENESS_SECONDS", uint256(3600));

        vm.startBroadcast(deployerKey);
        factory = new QieForgeFactory(deployer);
        router = new QieForgeRouter(address(factory));
        adapter = new QieOracleAdapter(deployer, maxStaleness);
        vm.stopBroadcast();

        console.log("QieForgeFactory:", address(factory));
        console.log("QieForgeRouter: ", address(router));
        console.log("QieOracleAdapter:", address(adapter));
        console.log("Deployer:", deployer);
    }
}
