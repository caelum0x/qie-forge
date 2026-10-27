// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {QieForgeFactory} from "../src/QieForgeFactory.sol";
import {QieForgeRouter} from "../src/QieForgeRouter.sol";
import {QieOracleAdapter} from "../src/oracle/QieOracleAdapter.sol";
import {QieForgeVault} from "../src/vault/QieForgeVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../test/mocks/MockAggregatorV3.sol";

/// @notice Deploys the FULL QIE Forge stack (factory, router, oracle,
/// two demo ERC20s, a vault) to a local/self-hosted anvil devnet and seeds
/// it with real liquidity and a real open vault position, so the live
/// frontend never has to show an empty state while the protocol itself
/// waits on a funded QIE Testnet/Mainnet deployer key (see docs/STATUS.md).
///
/// This is NOT a QIE Testnet or Mainnet deployment — the tokens, prices and
/// the "oracle" feed here are all mock/demo data on a disposable chain.
/// The frontend labels this clearly (NEXT_PUBLIC_QIE_FORGE_NETWORK=demo)
/// so nobody can mistake a demo swap for a real one.
///
/// Usage (against a running anvil, default anvil account #0 key):
///   forge script script/DeployDemo.s.sol:DeployDemo \
///     --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
contract DeployDemo is Script {
    uint256 internal constant WQIE_SEED = 1_000_000 ether; // 18 decimals
    uint256 internal constant TUSD_SEED = 1_000_000 * 1e6; // 6 decimals
    uint256 internal constant VAULT_BORROW_LIQUIDITY = 500_000 * 1e6; // TUSD seeded into the vault
    uint256 internal constant DEMO_COLLATERAL_DEPOSIT = 500_000 ether; // WQIE, ~$70,000 @ $0.14
    uint256 internal constant DEMO_BORROW_AMOUNT = 20_000 * 1e6; // TUSD (~28.6% LTV, well under 75%)

    function run()
        external
        returns (
            QieForgeFactory factory,
            QieForgeRouter router,
            QieOracleAdapter oracle,
            MockERC20 wqie,
            MockERC20 tusd,
            QieForgeVault vault
        )
    {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // --- Core AMM ---
        factory = new QieForgeFactory(deployer);
        router = new QieForgeRouter(address(factory));

        // --- Demo tokens ---
        wqie = new MockERC20("Wrapped QIE (Demo)", "WQIE", 18);
        tusd = new MockERC20("Test USD (Demo)", "TUSD", 6);
        wqie.mint(deployer, WQIE_SEED);
        tusd.mint(deployer, TUSD_SEED);

        // --- Seed AMM liquidity: 1 WQIE = 0.14 TUSD, mirrors the real QIE
        // mainnet oracle price captured in docs/STATUS.md ($0.1398) ---
        wqie.approve(address(router), 200_000 ether);
        tusd.approve(address(router), 28_000 * 1e6);
        router.addLiquidity(
            address(wqie), address(tusd), 200_000 ether, 28_000 * 1e6, 0, 0, deployer, block.timestamp + 3600
        );

        // --- Oracle + Vault (WQIE collateral, TUSD borrow) ---
        oracle = new QieOracleAdapter(deployer, 3600);
        MockAggregatorV3 wqieFeed = new MockAggregatorV3(8, "WQIE / USD (Demo)", 14_000_000); // $0.14, 8 decimals
        MockAggregatorV3 tusdFeed = new MockAggregatorV3(8, "TUSD / USD (Demo)", 100_000_000); // $1.00, 8 decimals
        oracle.setFeed(address(wqie), address(wqieFeed));
        oracle.setFeed(address(tusd), address(tusdFeed));

        vault = new QieForgeVault(wqie, tusd, oracle, 7_500, 8_000, 500, 0);

        // Seed the vault with borrowable TUSD liquidity (see
        // docs/qie-hackathon known gap: no lender-deposit flow yet, so a
        // demo/ops wallet funds the vault directly — tracked honestly as a
        // real pre-launch gap, not hidden).
        tusd.mint(address(vault), VAULT_BORROW_LIQUIDITY);

        // Open one real demo position so /vault never shows "no position".
        wqie.approve(address(vault), DEMO_COLLATERAL_DEPOSIT);
        vault.depositCollateral(DEMO_COLLATERAL_DEPOSIT);
        vault.borrow(DEMO_BORROW_AMOUNT);

        vm.stopBroadcast();

        console.log("== QIE Forge DEMO deployment ==");
        console.log("Factory:        ", address(factory));
        console.log("Router:         ", address(router));
        console.log("Oracle:         ", address(oracle));
        console.log("WQIE:           ", address(wqie));
        console.log("TUSD:           ", address(tusd));
        console.log("Vault:          ", address(vault));
        console.log("Deployer/demo user:", deployer);
    }
}
