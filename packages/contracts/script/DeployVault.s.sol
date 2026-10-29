// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QieForgeVault} from "../src/vault/QieForgeVault.sol";
import {QieOracleAdapter} from "../src/oracle/QieOracleAdapter.sol";

/// @notice Deploys a real QieForgeVault instance against already-deployed
/// assets and an already-deployed QieOracleAdapter (from script/Deploy.s.sol
/// — run that first). Separate from Deploy.s.sol on purpose: the AMM core
/// (Factory/Router/Adapter) has nothing it needs to know about which real
/// assets exist yet, but the vault is asset-specific and, per
/// packages/core/src/oracle.ts and docs/STATUS.md, QIE Mainnet oracle feeds
/// and QUSDC's real contract address were only independently confirmed on
/// Mainnet (not Testnet) and QUSDC's address specifically is still
/// unconfirmed anywhere as of this script's writing. This script never
/// guesses at those — it fails closed (reverts with a clear message) if the
/// required addresses aren't supplied, exactly the same posture
/// `QusdcClient`/`OracleClient` already use in the TS/Python/Rust SDKs.
///
/// Prerequisites (owner/operator steps, not something this script does):
///   1. Run script/Deploy.s.sol first, note the printed QieOracleAdapter address.
///   2. Decide the real collateral asset (e.g. a wrapped-QIE ERC-20 or
///      whatever this protocol's collateral side will be) and the real
///      borrow/quote asset (QUSDC once its address is confirmed, or any
///      other listed ERC-20).
///   3. Call `QieOracleAdapter.setFeed(collateralAsset, realAggregatorAddress)`
///      and `setFeed(borrowAsset, realAggregatorAddress)` for BOTH assets on
///      the real QIE Mainnet oracle aggregators (see packages/core/src/oracle.ts
///      for the confirmed addresses) — the vault's healthFactor()/borrow()/
///      liquidate() paths all revert NoFeedConfigured until both feeds exist.
///      This can be done before or after running this script; it must be
///      done before any real user calls borrow()/liquidate() against the
///      deployed vault.
///
/// Usage (mainnet — the hackathon's hard requirement, see plans/qie-hackathon.md):
///   DEPLOYER_PRIVATE_KEY=... \
///   QIE_FORGE_ORACLE_ADAPTER_ADDRESS=0x... \
///   QIE_FORGE_VAULT_COLLATERAL_ADDRESS=0x... \
///   QIE_FORGE_VAULT_BORROW_ADDRESS=0x... \
///     forge script script/DeployVault.s.sol:DeployVault \
///     --rpc-url qie_mainnet --broadcast --private-key $DEPLOYER_PRIVATE_KEY
///
/// Dry run against a local fork of the real target chain BEFORE spending any
/// real gas (no funds, no risk, exercises the exact same bytecode path):
///   anvil --fork-url https://rpc1mainnet.qie.digital
///   # in another shell, using anvil's funded default account #0:
///   DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
///   QIE_FORGE_ORACLE_ADAPTER_ADDRESS=<deploy Deploy.s.sol to the fork first, or reuse a real one> \
///   QIE_FORGE_VAULT_COLLATERAL_ADDRESS=<any real/mock ERC20 address reachable on the fork> \
///   QIE_FORGE_VAULT_BORROW_ADDRESS=<any real/mock ERC20 address reachable on the fork> \
///     forge script script/DeployVault.s.sol:DeployVault --rpc-url http://127.0.0.1:8545 --broadcast
contract DeployVault is Script {
    /// @dev Defaults match the demo deployment's risk parameters
    /// (DeployDemo.s.sol) and the Foundry test suite's baseline scenario —
    /// a reasonable, already-tested starting point, not a guess. Override
    /// any of these via env if the real launch wants different risk params.
    uint256 internal constant DEFAULT_LTV_BPS = 7_500; // 75%
    uint256 internal constant DEFAULT_LIQUIDATION_THRESHOLD_BPS = 8_000; // 80%
    uint256 internal constant DEFAULT_LIQUIDATION_BONUS_BPS = 500; // 5% at the curve's floor (barely underwater)
    uint256 internal constant DEFAULT_LIQUIDATION_BONUS_MAX_BPS = 2_000; // 20% once deeply underwater (healthFactor <= 0.5)
    uint256 internal constant DEFAULT_RATE_PER_SECOND_18 = 1_585_489_599; // ~5% APR
    uint256 internal constant DEFAULT_RESERVE_FACTOR_BPS = 1_000; // 10% of interest to protocol treasury

    error MissingRequiredAddress(string envVarName);

    function run() external returns (QieForgeVault vault) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address oracleAdapter = vm.envOr("QIE_FORGE_ORACLE_ADAPTER_ADDRESS", address(0));
        if (oracleAdapter == address(0)) revert MissingRequiredAddress("QIE_FORGE_ORACLE_ADAPTER_ADDRESS");

        address collateralAsset = vm.envOr("QIE_FORGE_VAULT_COLLATERAL_ADDRESS", address(0));
        if (collateralAsset == address(0)) revert MissingRequiredAddress("QIE_FORGE_VAULT_COLLATERAL_ADDRESS");

        address borrowAsset = vm.envOr("QIE_FORGE_VAULT_BORROW_ADDRESS", address(0));
        if (borrowAsset == address(0)) revert MissingRequiredAddress("QIE_FORGE_VAULT_BORROW_ADDRESS");

        // Treasury defaults to the deployer (a real address must exist --
        // the vault's constructor reverts ZeroTreasury() otherwise) but is
        // overridable so a real launch can point protocol revenue at a
        // multisig/DAO address instead of the deployer key.
        address vaultTreasury = vm.envOr("QIE_FORGE_VAULT_TREASURY_ADDRESS", deployer);

        uint256 ltvBps = vm.envOr("QIE_FORGE_VAULT_LTV_BPS", DEFAULT_LTV_BPS);
        uint256 liquidationThresholdBps =
            vm.envOr("QIE_FORGE_VAULT_LIQUIDATION_THRESHOLD_BPS", DEFAULT_LIQUIDATION_THRESHOLD_BPS);
        uint256 liquidationBonusBps = vm.envOr("QIE_FORGE_VAULT_LIQUIDATION_BONUS_BPS", DEFAULT_LIQUIDATION_BONUS_BPS);
        uint256 liquidationBonusMaxBps =
            vm.envOr("QIE_FORGE_VAULT_LIQUIDATION_BONUS_MAX_BPS", DEFAULT_LIQUIDATION_BONUS_MAX_BPS);
        uint256 ratePerSecond18 = vm.envOr("QIE_FORGE_VAULT_RATE_PER_SECOND_18", DEFAULT_RATE_PER_SECOND_18);
        uint256 reserveFactorBps = vm.envOr("QIE_FORGE_VAULT_RESERVE_FACTOR_BPS", DEFAULT_RESERVE_FACTOR_BPS);

        vm.startBroadcast(deployerKey);
        vault = new QieForgeVault(
            IERC20(collateralAsset),
            IERC20(borrowAsset),
            QieOracleAdapter(oracleAdapter),
            ltvBps,
            liquidationThresholdBps,
            liquidationBonusBps,
            liquidationBonusMaxBps,
            ratePerSecond18,
            vaultTreasury,
            reserveFactorBps
        );
        vm.stopBroadcast();

        console.log("QieForgeVault:  ", address(vault));
        console.log("  collateralAsset:", collateralAsset);
        console.log("  borrowAsset:    ", borrowAsset);
        console.log("  oracleAdapter:  ", oracleAdapter);
        console.log("  ltvBps:", ltvBps);
        console.log("  liquidationThresholdBps:", liquidationThresholdBps);
        console.log("  liquidationBonusBps:", liquidationBonusBps);
        console.log("  liquidationBonusMaxBps:", liquidationBonusMaxBps);
        console.log("  ratePerSecond18:", ratePerSecond18);
        console.log("  treasury:", vaultTreasury);
        console.log("  reserveFactorBps:", reserveFactorBps);
        console.log("Deployer:", deployer);
        console.log("");
        console.log(
            "REMINDER: this vault will revert NoFeedConfigured on borrow()/healthFactor()/liquidate() until"
        );
        console.log(
            "QieOracleAdapter.setFeed() has been called for BOTH collateralAsset and borrowAsset above."
        );
    }
}
