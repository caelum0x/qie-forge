# QIE Forge — demo video walkthrough script

Judge-ready, numbered script for recording the hackathon's required demo
video. Every step names an exact URL, exact action, or exact command, with
the exact output it produced when last verified live (2026-10-28). Re-run any
command yourself before recording — all of this is real, nothing staged.

No video recording (screen capture + voiceover) was produced in this pass —
this environment has no microphone/screen-recording capability. This is the
script to record it from, not a substitute for the recording itself.

Target length: 3-4 minutes. Suggested structure below maps to that.

---

## 1. Open — the problem (15s)

Say: "QIE is a live EVM L1 with a working explorer, wallet, and oracle — but
no public DEX and no public lending protocol. QIE Forge is a clean-room AMM
and over-collateralized lending vault, built from scratch for this
hackathon."

## 2. Live frontend — real on-chain data (30s)

Navigate to **https://qie-forge.vercel.app**.

Point out: no login wall, HTTP 200, real data on every request. Call out the
two stat cards:

- Testnet (1983) block number
- Mainnet (1990) block number
- BTC/USDT and QIE/USDT prices, labeled "live from QIE Oracle"

Last verified live output (re-run `curl -s https://qie-forge.vercel.app/` and
look for these strings before recording — numbers will have moved on,
that's expected and proves it's live, not cached):

```
Testnet (1983) #9411490
Mainnet (1990) #11487508
BTC / USDT  $81,117.95
QIE / USDT  $0.1399
```

## 3. The oracle-docs bug — the differentiator story (45s)

Say: "While building this we found QIE's own Oracle docs are wrong."

Show (terminal, or just state it — this is the kind of detail that separates
a real build from a copy-paste integration):

```bash
# QIE's docs say: function getPrice(string) view returns (uint256)
# Calling that exact signature on the real deployed BTC oracle reverts.
cast call 0x9E596d809a20A272c788726f592c0d1629755440 \
  "getPrice(string)(uint256)" "BTC" \
  --rpc-url https://rpc1mainnet.qie.digital
# -> revert

# The real interface is a Chainlink AggregatorV3Interface clone:
cast call 0x9E596d809a20A272c788726f592c0d1629755440 \
  "decimals()(uint8)" --rpc-url https://rpc1mainnet.qie.digital
# -> 8
cast call 0x9E596d809a20A272c788726f592c0d1629755440 \
  "description()(string)" --rpc-url https://rpc1mainnet.qie.digital
# -> "BTC / USDT"
```

Then show the CLI reading it correctly:

```bash
node packages/cli/dist/index.js oracle-price --network mainnet --asset BTC
```

## 4. Swap — real AMM quote through the live UI (45s)

Navigate to **https://qie-forge.vercel.app/swap**.

Point out the "demo" banner — explicitly labeled as a disposable demo
network (self-hosted anvil devnet, chain ID 31337), not QIE Testnet/Mainnet
(see step 7 for why).

Type `10` into the WQIE input. Show the TUSD output field fill in with a real
computed quote (`1.39573` TUSD at last verification — exact number moves
slightly as the demo pool accrues fees from other testers, that's expected).

Equivalent API call to show it's a real on-chain read, not client-side math:

```bash
curl "https://qie-forge.vercel.app/api/quote?amountIn=10000000000000000000&path=0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0&path=0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9"
# -> {"amounts":["10000000000000000000","1395730"]}
```

## 5. Vault — real lending position and health factor (30s)

Navigate to **https://qie-forge.vercel.app/vault**.

Show the open demo position: 500,000 WQIE collateral, 20,000 TUSD debt,
health factor 2.8x, all read live from the deployed `QieForgeVault` contract.

```bash
curl "https://qie-forge.vercel.app/api/vault-position?user=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
# -> {"collateral":"500000000000000000000000","debtPrincipal":"20000000000",
#     "healthFactor":"2800000000000000000","currentDebt":"20000000000"}
```

## 6. Contracts and tests — technical depth (45s)

Terminal:

```bash
cd packages/contracts && forge test -vv
# -> Ran 4 test suites: 41 tests passed, 0 failed, 0 skipped (41 total tests)
```

Say: "41 Foundry tests cover constant-product invariants, LP share math, fee
accrual, TWAP accumulation, multi-hop routing including 3-pool paths and
exact-output swaps, oracle staleness/decimals/rotation edge cases, and vault
liquidation edge cases."

Show one specific test by name as the security story:

```bash
forge test --match-test test_liquidation_minimalRepayStillZeroesDebt_whenCollateralExhausted -vv
```

Say: "This test reproduces a real bad-debt exploit an external reviewer
flagged — a liquidator could choose a tiny repay amount and leave debt
stranded with zero collateral behind it. We verified it ourselves by reading
the contract directly, fixed it with ERC4626-style lender accounting plus a
bad-debt write-off, and this test proves debt and collateral now always
reach zero together."

## 7. Honest close — what's still open (20s)

Say: "Everything above is real and running right now. What's not done yet:
these contracts aren't deployed to QIE Testnet or Mainnet — that needs a
funded deployer wallet, which is the one genuinely owner-gated step left.
The demo you just saw runs the exact same deployment script and contract
bytecode this would use on QIE itself — flipping one environment variable
from `demo` to `mainnet` with real addresses is the only change needed."

---

## Quick reference — exact commands used above

```bash
curl -s https://qie-forge.vercel.app/
curl -s "https://qie-forge.vercel.app/api/quote?amountIn=10000000000000000000&path=0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0&path=0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9"
curl -s "https://qie-forge.vercel.app/api/vault-position?user=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
cd packages/contracts && forge test -vv
node packages/cli/dist/index.js chain-info --network testnet
node packages/cli/dist/index.js chain-info --network mainnet
node packages/cli/dist/index.js oracle-price --network mainnet --asset BTC
node packages/cli/dist/index.js oracle-price --network mainnet --asset QIE
```
