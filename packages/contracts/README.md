# @qie-forge/contracts

Foundry package for QIE Forge's Solidity contracts: `QieForgeFactory`/
`QieForgePair`/`QieForgeRouter` (clean-room constant-product AMM) and
`QieForgeVault` (overcollateralized lending), plus `QieOracleAdapter`
(normalizes QIE's real Chainlink-shaped oracle aggregators). See the repo
root `README.md`, `docs/STATUS.md`, and `plans/qie-hackathon.md` for the
full product/research story — this file only covers building, testing, and
deploying this package.

## Build & test

```shell
forge build
forge test        # 44/44 as of 2026-10-29 — AMM invariants, LP math, fee
                   # accrual, TWAP, router multi-hop, oracle staleness,
                   # vault LTV/health-factor/interest/liquidation
```

## Deploy

Deployment is split into two scripts, run in order, because the AMM core
has no asset-specific state but the vault does:

1. **`script/Deploy.s.sol`** — deploys `QieForgeFactory`, `QieForgeRouter`,
   and a bare `QieOracleAdapter`. No real asset addresses needed.

   ```shell
   DEPLOYER_PRIVATE_KEY=0x... \
     forge script script/Deploy.s.sol:Deploy \
     --rpc-url qie_mainnet --broadcast --private-key $DEPLOYER_PRIVATE_KEY
   ```

2. **`script/DeployVault.s.sol`** — deploys `QieForgeVault` against the
   oracle adapter from step 1 and real collateral/borrow asset addresses.
   Fails closed (reverts with a named error) if any required address is
   unset — it will not deploy against a guessed address.

   ```shell
   DEPLOYER_PRIVATE_KEY=0x... \
   QIE_FORGE_ORACLE_ADAPTER_ADDRESS=0x... \
   QIE_FORGE_VAULT_COLLATERAL_ADDRESS=0x... \
   QIE_FORGE_VAULT_BORROW_ADDRESS=0x... \
     forge script script/DeployVault.s.sol:DeployVault \
     --rpc-url qie_mainnet --broadcast --private-key $DEPLOYER_PRIVATE_KEY
   ```

   After this, call `QieOracleAdapter.setFeed(asset, aggregator)` for
   **both** the collateral and borrow assets using QIE's real deployed
   oracle aggregator addresses (see `packages/core/src/oracle.ts`) — the
   vault reverts `NoFeedConfigured` on `borrow()`/`healthFactor()`/
   `liquidate()` until both feeds exist.

`[rpc_endpoints]` in `foundry.toml` already has `qie_testnet` and
`qie_mainnet` wired to the real, verified RPC URLs (see `docs/STATUS.md`
for how the previously-documented testnet RPC was found dead and replaced).

### Dry run before spending real gas

Both scripts above were verified end-to-end (2026-10-29) against a real
local fork of live QIE Mainnet — no real funds, no real risk, same exact
bytecode path:

```shell
anvil --fork-url https://rpc1mainnet.qie.digital
# in another shell, using anvil's funded default test account:
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast
```

See `docs/STATUS.md` for the full transcript (real addresses, real block
numbers) and `script/DeployVault.s.sol`'s doc comment for the equivalent
vault dry-run command.

### Demo deployment (not Testnet/Mainnet)

`script/DeployDemo.s.sol` deploys the full stack plus two mock ERC-20s to
a disposable anvil devnet and seeds real liquidity + a real open vault
position — this is what the live frontend's `/swap` and `/vault` point at
by default so they never show an empty state. It is explicitly labeled
`demo` everywhere (`NEXT_PUBLIC_QIE_FORGE_NETWORK=demo`) and is not a
Testnet or Mainnet deployment.

## License

MIT.
