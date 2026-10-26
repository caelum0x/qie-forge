# QIE Forge — build status (2026-10-26)

Honest status, written the same day the repo was created. Nothing below is
aspirational — every claim has a command you can re-run.

## Built and verified: contracts (local EVM, Foundry)

```
cd packages/contracts && forge test -vv
```

Real output captured during development:

```
Ran 5 tests for test/QieOracleAdapter.t.sol:QieOracleAdapterTest
[PASS] test_normalizesRealBtcOracleDecimalsTo18() (gas: 49587)
[PASS] test_onlyOwnerCanSetFeed() (gas: 15823)
[PASS] test_revertsOnNonPositiveAnswer() (gas: 52700)
[PASS] test_revertsOnStalePrice() (gas: 52718)
[PASS] test_revertsWhenNoFeedConfigured() (gas: 13393)
Suite result: ok. 5 passed; 0 failed; 0 skipped

Ran 5 tests for test/QieForgeRouter.t.sol:QieForgeRouterTest
[PASS] test_addLiquidity_createsPairAndMintsShares() (gas: 12539)
[PASS] test_deadlineExpired_reverts() (gas: 46375)
[PASS] test_multiHopSwap_matchesLibraryQuote() (gas: 169416)
[PASS] test_removeLiquidity_returnsUnderlyingTokens() (gas: 129289)
[PASS] test_swapExactTokensForTokens_revertsBelowMinOut() (gas: 67232)
Suite result: ok. 5 passed; 0 failed; 0 skipped

Ran 8 tests for test/QieForgeVault.t.sol:QieForgeVaultTest
[PASS] test_borrow_exceedingLtv_reverts() (gas: 154631)
[PASS] test_depositAndBorrow_withinLtv_succeeds() (gas: 212647)
[PASS] test_healthFactor_above1WhenSafe() (gas: 216680)
[PASS] test_interest_accruesOverTime() (gas: 212595)
[PASS] test_liquidation_cannotSeizeMoreThanAvailableCollateral() (gas: 251175)
[PASS] test_liquidation_revertsWhenPositionHealthy() (gas: 250476)
[PASS] test_liquidation_succeedsWhenUnderwater_andPaysBonus() (gas: 295911)
[PASS] test_withdraw_belowLtvThreshold_reverts() (gas: 220480)
Suite result: ok. 8 passed; 0 failed; 0 skipped

Ran 7 tests for test/QieForgePair.t.sol:QieForgePairTest
[PASS] test_burn_returnsProportionalShare() (gas: 236495)
[PASS] test_firstMint_locksMinimumLiquidity() (gas: 210731)
[PASS] test_mint_proportionalOnSecondDeposit() (gas: 261258)
[PASS] test_priceCumulative_accumulatesOverTime() (gas: 260370)
[PASS] test_protocolFee_mintsToFeeToOnGrowth() (gas: 458916)
[PASS] test_swap_respectsConstantProductWithFee() (gas: 239521)
[PASS] test_swap_revertsIfInvariantViolated() (gas: 234940)
Suite result: ok. 7 passed; 0 failed; 0 skipped

Ran 4 test suites: 25 tests passed, 0 failed, 0 skipped (25 total tests)
```

What these actually exercise (not just "it compiles"):
- Constant-product invariant preservation across swaps, including the fee
  math making k strictly non-decreasing.
- LP share math: first-mint minimum-liquidity lock, proportional minting on
  subsequent deposits, proportional burn payout.
- The router's quoted amounts matching a real 2-hop swap's actual output.
- Slippage (`InsufficientOutputAmount`) and deadline (`Expired`) protection
  actually reverting.
- TWAP price accumulation increasing after a real `vm.warp` + `sync()`.
- The protocol-fee switch actually minting LP shares to `feeTo` after real
  fee-generating swaps.
- `QieOracleAdapter` normalizing a mock feed shaped exactly like the real
  BTC oracle (8 decimals) to 60,123.45 USD at 18 decimals, and reverting on
  a non-positive answer, a stale `updatedAt`, and a non-owner `setFeed`
  call.
- The lending vault: borrow blocked above the LTV cap, withdrawal blocked
  if it would breach LTV, health-factor computed correctly against a known
  hand-calculated value, interest actually accruing over a simulated year,
  liquidation blocked while healthy, liquidation succeeding and paying the
  exact bonus-adjusted collateral amount once simulated underwater, and
  liquidation correctly capping at available collateral in an extreme
  crash.

## Built and verified: SDK + CLI (real network calls)

```
node packages/cli/dist/index.js chain-info --network testnet
```
```json
{
  "network": "testnet",
  "chainId": 1983,
  "blockNumber": "9390331",
  "blockHash": "0xc454c681c4594a90ee2f6b14e3c940a0d79d3a1db809565efad05687d58331ac",
  "timestamp": "2026-10-26T20:31:38.000Z",
  "gasPriceWei": "6",
  "rpcUrl": "https://testnet.qie.digital/api/eth-rpc"
}
```

```
node packages/cli/dist/index.js oracle-price --network mainnet --asset BTC
```
```json
{
  "asset": "BTC",
  "network": "mainnet",
  "contract": "0x9E596d809a20A272c788726f592c0d1629755440",
  "description": "BTC / USDT",
  "price": 79896.24773011,
  "rawAnswer": "7989624773011",
  "decimals": 8,
  "roundId": "48052",
  "updatedAt": "2026-10-26T19:03:51.000Z"
}
```

```
node packages/cli/dist/index.js oracle-price --network mainnet --asset QIE
```
```json
{
  "asset": "QIE",
  "network": "mainnet",
  "contract": "0x3Bc617cF3A4Bb77003e4c556B87b13D556903D17",
  "description": "QIE / USDT",
  "price": 0.13982897,
  "rawAnswer": "13982897",
  "decimals": 8,
  "roundId": "20136",
  "updatedAt": "2026-10-25T22:06:47.000Z"
}
```

Mainnet block number at the same time: 11,462,255. Testnet: 9,390,331. These
are real, live chain states, not fixtures.

## Not yet done (honest gaps, not hidden)

- **No on-chain Testnet or Mainnet deployment of the protocol yet.**
  `script/Deploy.s.sol` is written and compiles, but deploying costs real
  gas and needs a funded deployer key. QIE's testnet faucet
  (`qie.digital/faucet`) is a connect-a-wallet web app, not a plain
  address-in/tokens-out API — claiming testnet QIE for a fresh deployer
  key is a genuine owner/operator step, not something this session's
  API/CLI access could complete. Nothing about the contracts themselves is
  blocked; only the broadcast step is.
- **No frontend.** Planned for week 4 of the build (see
  `plans/qie-hackathon.md`), using the already-built
  `walletConnect.ts` constants for the real QIE Wallet EIP-1193/EIP-6963
  integration.
- **Python and Rust SDK clients are directory-scaffolded only** —
  `packages/python/` and `packages/rust/` exist but have no implementation
  yet. Not claimed as done anywhere in this README.
- **QUSDC integration is fail-closed, not active** — the real QUSDC
  contract address was not independently confirmed during this build (see
  README). `QusdcClient` and the vault's quote-asset path both require an
  explicit, verified address before they'll do anything.
- **QIE ID is not integrated** — no public API or contract for it was
  found during this research pass.
