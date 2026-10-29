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
    // A real, nonzero demo of QieForgeVault.borrowCap: deliberately above
    // DEMO_BORROW_AMOUNT (so the demo's own open position opens fine) but
    // well below VAULT_BORROW_LIQUIDITY (so there's real idle liquidity a
    // second borrower could still try to draw against, and genuinely hit
    // the cap against) -- see scripts/borrow-cap-demo.sh for the live
    // proof against this exact deployed bytecode.
    uint256 internal constant DEMO_BORROW_CAP = 100_000 * 1e6; // TUSD

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
        // maxStaleness is deliberately ~10 years, not a realistic
        // production value: a real QIE Mainnet oracle keeps updating on
        // its own, but this demo's MockAggregatorV3 only ever gets the one
        // `updatedAt` timestamp set at deploy time and nothing refreshes it
        // afterward -- a 1-hour window (the original value here) made
        // `borrow()`/`healthFactor()` revert with StalePrice for every real
        // user roughly an hour after each deploy, which is exactly what
        // happened to the live demo twice on 2026-10-28 (see
        // plans/qie-hackathon.md). Not a security loosening: this is a
        // disposable chain with zero real value behind its prices.
        oracle = new QieOracleAdapter(deployer, 315_360_000);
        MockAggregatorV3 wqieFeed = new MockAggregatorV3(8, "WQIE / USD (Demo)", 14_000_000); // $0.14, 8 decimals
        MockAggregatorV3 tusdFeed = new MockAggregatorV3(8, "TUSD / USD (Demo)", 100_000_000); // $1.00, 8 decimals
        oracle.setFeed(address(wqie), address(wqieFeed));
        oracle.setFeed(address(tusd), address(tusdFeed));

        // 10% reserve factor: a real, nonzero demo of the protocol's own
        // revenue mechanism (QieForgeVault.reserveFactorBps), even though
        // this demo's RATE_PER_SECOND_18 is 0 so no interest -- and
        // therefore no reserves -- actually accrues on this disposable
        // chain. `deployer` doubles as the demo treasury.
        //
        // Liquidation bonus: 5% at the curve's floor (barely underwater)
        // scaling up to a real 20% once a position is deeply underwater
        // (healthFactor <= 0.5) -- see QieForgeVault.liquidationBonusMaxBps.
        // This demo's own open position stays healthy on purpose (judges
        // browsing the live site should never see it as "about to be
        // liquidated") -- the curve itself is proven against this exact
        // deployed bytecode on a throwaway position on this same chain,
        // see docs/STATUS.md's "severity-scaled liquidation incentive
        // curve" entry for the real `cast call`/`liquidate()` proof (no
        // standalone script exists for this one, unlike borrowCap below).
        // Borrow cap: a real, nonzero demo of QieForgeVault.borrowCap
        // (100,000 TUSD) -- see DEMO_BORROW_CAP's own doc comment.
        vault = new QieForgeVault(wqie, tusd, oracle, 7_500, 8_000, 500, 2_000, 0, deployer, 1_000, DEMO_BORROW_CAP);

        // Seed the vault with borrowable TUSD liquidity via a direct mint
        // rather than deposit(): this is deliberately a one-way ops/demo
        // contribution, not a lender position expecting to be withdrawn
        // back out later. QieForgeVault.MINIMUM_LENDER_SHARES (added
        // 2026-10-28 after a real exploit was found against this exact
        // seeding pattern, see plans/qie-hackathon.md) now walls this
        // pre-funded balance off from whoever calls deposit() first, so
        // this shortcut is safe to keep using for demo purposes.
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
