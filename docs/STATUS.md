# QIE Forge — build status (updated 2026-10-29)

Honest status. Nothing below is aspirational — every claim has a command
you can re-run, and most have a live URL you can open right now.

**Live public app:** https://qie-forge.vercel.app (home page renders real,
live testnet/mainnet block numbers and real QIE Oracle prices on every
request — see "Built and verified: frontend" below).

## 2026-10-29 (even later): deposit() panic after a full bad-debt wipeout — a real permanent DoS on new lending liquidity

This plan's own previous pass (the bad-debt-write-off-vs-reserves fix
below) flagged this exact gap and deliberately left it unfixed, one real
gap per pass. Closed it this pass.

**Real gap, confirmed via `git stash` against this repo's own pre-fix
bytecode before writing anything**: once a full bad-debt write-off (see
below) drives `totalAssets()` to exactly `0` while `totalLenderShares()`
is still nonzero (the wiped-out lender never called `withdraw()`),
`deposit()`'s exchange-rate formula divides by `assetsBefore == 0` and
reverts with a bare `Panic(0x12)` — on *every* future `deposit()` call,
forever, since nothing forces the stale lender to ever withdraw their
now-worthless shares. New lending liquidity is permanently blocked. A
throwaway repro test against the real pre-fix contract reproduced exactly
this: `[FAIL: panic: division or modulo by zero (0x12)]
test_repro_depositAfterFullWipeout_panicsPreFix()`.

**Fixed with an epoch-stamped share balance, not a silent reset**: added
`lenderEpoch` (bumped once per full-wipeout reset) and
`_lenderSharesEpoch[address]`; the public `lenderShares(address)` getter
(same external signature the frontend already calls) now reads a user's
raw balance only if it was stamped with the *current* epoch, else `0`.
`deposit()` gained a third branch — `totalLenderShares > 0 && assetsBefore
== 0` — that bumps the epoch, resets `totalLenderShares` to `0`, and mints
the new depositor fresh 1:1 shares. This matters, not just a cosmetic
"stop reverting" patch: without the epoch stamp, a plain reset would leave
every prior stale holder's raw balance intact and large enough to pass
`withdraw()`'s own-balance check once the pool has real value in it
again — letting old, already-wiped-out lenders dilute or outright drain a
fresh depositor's money. The epoch stamp closes that off: a stale holder's
effective balance reads `0` forever after the reset, confirmed below.

**Verified two ways, both real**:
1. `forge test`: 1 new regression test,
   `test_deposit_afterFullBadDebtWipeout_withoutPriorWithdraw_mintsFreshSharesInsteadOfReverting`
   — full setup (lender deposits, borrower borrows the entire idle balance,
   price crashes, a real `liquidate()` call fully writes off the debt),
   then asserts a second depositor's `deposit()` succeeds instead of
   reverting, mints clean 1:1 shares, the stale lender's `lenderShares()`
   reads `0`, and the stale lender's own `withdraw(1)` reverts
   `InsufficientShares`. **64 → 65/65 pass**, zero regressions on the
   other 64.
2. **Live, on real deployed bytecode** (a fresh throwaway
   WQIE/TUSD/oracle/vault stack deployed via `forge create` against the
   persistent self-hosted anvil devnet, `http://130.61.180.42:8647` — the
   public demo's own vault was never touched, same posture every prior
   pass used, since its 0%-APR demo position can't reach this state):
   reproduced the exact state live (`totalAssets()` → `0`,
   `totalLenderShares()` → `700000000`), then called the real `deposit()`
   from a second account — it succeeded (`status: 1`), landing exactly on
   `totalAssets() = 50000000`, `totalLenderShares() = 50000000`,
   `lenderEpoch: 0 → 1`, `lenderShares(lender2) = 50000000`, and
   `lenderShares(original stale lender) = 0`. The stale lender's own
   `withdraw(1)` call against the live contract reverted with the real
   `InsufficientShares` custom error, confirmed via `cast send`. The live
   production demo (`qie-forge.vercel.app/api/vault-position`) was
   re-checked afterward and still reports its own unrelated, unchanged
   500,000 WQIE / 20,000 TUSD position — this fix didn't require touching
   the public demo's deployment.

**Commit**: `pending` (this session) — `packages/contracts/src/vault/
QieForgeVault.sol`, `packages/contracts/test/QieForgeVault.t.sol`,
`README.md`, `SUBMISSION.md`, `docs/STATUS.md`, `docs/TEAM-PRESENTATION.md`.

## 2026-10-29 (newest): bad-debt write-off vs. realized protocol reserves — a real insolvency/DoS gap, distinct from the borrow-cap work below

Task scope this pass: one more real, substantial DeFi gap, distinct from
every fix below. Read this file, `plans/qie-hackathon.md`, and the
contracts directly first, same as every prior pass.

**Real gap found by reading `QieForgeVault.liquidate()`'s bad-debt branch
against `protocolReserves`'s own accounting**: a bad-debt write-off
shrinks `totalDebtPrincipal` (the vault's real backing) by the full
written-off amount, but never touched the separate, already-*realized*
`protocolReserves` bucket (interest the treasury's cut has already been
folded into via a real `_accrue` touch, tracked independently of
`totalDebtPrincipal`). With a real nonzero `reserveFactorBps` — every real
deploy of this vault uses one, see `DeployVault.s.sol`'s
`DEFAULT_RESERVE_FACTOR_BPS` — a position whose *entire* debt gets written
off as bad debt (the exact scenario `test_liquidation_
cannotSeizeMoreThanAvailableCollateral` already exercises for a smaller
case) can leave `protocolReserves` larger than `totalDebtPrincipal + the
vault's idle borrowAsset balance` combined — the vault's only two sources
of real backing. `totalAssets()` computes `idle + debt - totalReserves()`;
once `totalReserves()` exceeds `idle + debt`, that subtraction underflows
and reverts with a `Panic(0x11)` on *every single future call* —
including every lender's `deposit()` and `withdraw()` — permanently
freezing all lender funds in the vault, forever, since `withdrawReserves()`
itself needs idle liquidity that may never arrive once the vault is
bricked this way. Confirmed via `git stash` against this repo's own
pre-fix bytecode: the exact scenario below (full write-off after a real
year of 10%-reserve-factor interest accrual) genuinely left `vm.
expectRevert()` passing on `totalAssets()` — a real, reproducible
Panic(0x11), not a hypothetical.

**Built**: `liquidate()` now clamps `protocolReserves` down to
`totalDebtPrincipal + borrowAsset.balanceOf(address(this))` (the vault's
actual post-write-off backing) the moment a bad-debt write-off would
otherwise push it above that, emitting a new `ProtocolReservesWrittenOff`
event with the haircut amount. The clamp is a no-op whenever the
invariant was never actually at risk (ample idle liquidity, or a badDebt
small enough that lenders' own cushion absorbs it first) — lenders still
correctly bear bad debt first, exactly as the pre-existing design already
documents ("shrinking `totalDebtPrincipal` shrinks every share's claim
proportionally"); the clamp only ever takes the *excess* beyond lenders'
full wipeout out of already-realized treasury revenue, never the other
way around.

**Verified two ways, both real**:
1. `forge test`: 2 new regression tests —
   `test_liquidate_fullBadDebtWriteOff_doesNotBrickTotalAssets` (a lender
   deposits exactly what a borrower then fully borrows out, a real year of
   ~5% APR / 10% reserve-factor interest accrues, the collateral price is
   crashed to $0.00000001, and the entire position is liquidated as a full
   write-off: `protocolReserves` lands exactly clamped to the vault's
   remaining backing, `totalAssets()` returns `0` instead of
   underflow-reverting, the wiped-out lender's own `withdraw()` succeeds
   for `0` instead of reverting, and a brand-new lender can `deposit()`
   into the now-pristine vault afterward) and
   `test_liquidate_partialBadDebt_leavesReservesUntouched_whenInvariantNeverAtRisk`
   (a milder crash with ample untouched idle liquidity from the lender: the
   clamp never engages, reserves reflect only the real reserve-factor cut
   actually realized). **62 → 64/64 pass**, zero regressions on the other
   62.
2. **Live, on real deployed bytecode**, two ways — the live public demo's
   own vault can't exercise this (its `ratePerSecond18` is deliberately
   `0`, so it never accrues interest or reserves at all; no demo redeploy
   was needed or done this pass):
   - A new one-command demo script,
     `scripts/bad-debt-reserve-clamp-demo.sh` (mirroring
     `borrow-cap-demo.sh`'s existing pattern): spins up a disposable local
     anvil, deploys a real throwaway `QieForgeVault` (its own fresh
     WQIE/TUSD/oracle, ~5% APR, a real 10% reserve factor — not the
     public demo's own 0%-rate vault), reproduces the exact scenario above
     end-to-end against that deployed bytecode, and exits cleanly (exit
     code 0, no orphaned anvil process left behind afterward).
   - The same scenario re-proven against the *persistent* self-hosted
     chain (`http://130.61.180.42:8647`), on a separate throwaway
     WQIE/TUSD/oracle/vault stack deployed via `forge create` (so the
     public demo's own open position was never touched, same posture
     every prior pass's second verification path used) — real on-chain
     `liquidate()` tx
     `0xc4cdb5cb99a1340586eecee63be8d10bf6c673a6613cfead6a4cef3f9adaae08`
     fully wrote off a 735,000,002-unit debt; `totalDebtPrincipal` landed
     at `0`, `protocolReserves` clamped to `9` (exactly the vault's
     remaining idle balance), and `totalAssets()` returned `0` without
     reverting.

**A second, distinct edge case found live while building the demo — NOT
fixed this pass, flagged for a future one**: calling `deposit()` directly
(instead of first letting the wiped-out lender `withdraw()`) while
`totalAssets() == 0` but `totalLenderShares() > 0` reverts with a genuine
division-by-zero `Panic(0x12)` in `deposit()`'s exchange-rate branch
(`shares = (amount * totalLenderShares) / assetsBefore`, with
`assetsBefore == 0`). This is a real, separately-reachable gap (a vault
whose existing lenders have all been wiped to exactly zero by bad debt,
but whose shares haven't been withdrawn yet, can't accept a fresh deposit
until someone withdraws first) — distinct from the insolvency/DoS gap
fixed above, which is about `protocolReserves` exceeding backing, not
about `totalAssets()` legitimately reaching zero. Left out of this pass's
scope deliberately (one real gap per pass) rather than scope-creeping the
fix; see `plans/qie-hackathon.md` for the same note.

**Owner-only blocker, unchanged, still the single remaining gate**: a
funded QIE deployer wallet for the real Testnet/Mainnet broadcast
(`qie.digital/faucet` is a connect-a-wallet flow for testnet; mainnet
needs real funded QIE) — both genuine owner/operator steps, unautomatable
from this environment. Everything up to and including that broadcast
command is real, tested, and ready, same as every pass before this one.

## 2026-10-29 (latest): aggregate borrow cap shipped, distinct from the liquidation-curve work below

Real gap found by reading `QieForgeVault.borrow()` itself, after the
severity-scaled liquidation curve below: per-position `ltvBps` was the
*only* check on how much the vault could lend out in aggregate. A single
well-collateralized borrower (or several) could grow `totalDebtPrincipal`
arbitrarily large with nothing else gating it, even though per-position
LTV says nothing about whether the vault *as a whole* has grown larger
than this market can safely absorb — real risk management (oracle feed
liquidity depth, how much of the collateral asset could actually be sold
to cover a cluster of simultaneous liquidations) bounds this
independently of any one borrower's own collateralization. This is
exactly the real-world precedent this gap was weighed against: Compound's
per-market `borrowCaps` mapping and Aave's per-reserve borrow cap both
exist for this exact reason, independent of each protocol's own
per-position LTV checks.

**Built**: an immutable `QieForgeVault.borrowCap` (0 disables the cap
entirely — unlimited, the exact pre-existing behavior, same
sentinel-disables-the-feature posture `reserveFactorBps == 0` and
`liquidationBonusMaxBps == liquidationBonusBps` already use). `borrow()`
now checks the vault's aggregate debt (`totalDebtPrincipal`, recomputed
the same way the existing LTV check already does) against `borrowCap`
before accepting a new draw. Only new `borrow()` principal draws are
gated — interest accruing on already-outstanding debt (via `_accrue`
elsewhere) is never blocked, exactly like the existing `ExceedsLtv` check
only ever gates new draws and never retroactively reverts interest
accrual on a position already over threshold.

**Verified two ways:**
1. `forge test`: 5 new regression tests — the `ZERO_BORROW_CAP` sentinel
   genuinely disables the feature (a borrow far larger than any real cap
   but still safely under LTV still succeeds); a borrow comfortably under
   LTV still reverts with the real `BorrowCapExceeded` once it would push
   aggregate debt past a configured cap, leaving no partial debt behind;
   the exact boundary — landing precisely on the cap succeeds, 1 unit over
   reverts; the cap is aggregate across *multiple* borrowers sharing the
   same vault, not per-position (a second borrower is blocked by the
   first's draws even though individually under their own LTV); and
   interest accruing on already-outstanding debt can push accrued debt
   past the cap without reverting anything, while a *new* `borrow()` draw
   at that point still correctly reverts and `repay()` is never gated at
   all. **57 → 62/62 pass**, zero regressions on the other 57.
2. **Live, on the real self-hosted demo chain**
   (`http://130.61.180.42:8647`, not just Foundry's test EVM), two ways:
   - A brand-new one-command demo script, `scripts/borrow-cap-demo.sh`
     (mirroring `liquidation-bot-demo.sh`'s pattern): spins up a
     disposable local anvil, deploys the real `DeployDemo.s.sol` stack
     (now setting a real, nonzero 100,000 TUSD `borrowCap`), deposits
     extra collateral so the cap — not LTV — is the binding constraint,
     then proves the exact boundary against that real deployed bytecode:
     a `borrow()` landing exactly on the remaining headroom succeeds
     (`totalDebtPrincipal` becomes exactly `100000000000`), the very next
     `borrow(1)` reverts with the real `BorrowCapExceeded` custom error,
     and `totalDebtPrincipal` stays unchanged by the reverted call. Exits
     cleanly (exit code 0), no orphaned anvil process left behind.
   - The same exact boundary re-proven against the *persistent*
     self-hosted chain, on a separate throwaway vault instance deployed
     via `forge create` (so the public demo's own open position was never
     touched, same posture the liquidation-curve work below used): real
     `borrow()` tx
     `0xc71dd5c403441aeb747dc04a6cf3909c400e0f392047fe8fe762ad4ae77af794`
     landed exactly on a 1,000 TUSD cap and succeeded; the next
     `borrow(1)` reverted with `BorrowCapExceeded`, `totalDebtPrincipal`
     unchanged.

**Redeployed the live public demo** (`DeployDemo.s.sol` now passes a real
100,000 TUSD `DEMO_BORROW_CAP`, deliberately above the demo's own 20,000
TUSD pre-opened position so it opens fine, and well below the 500,000
TUSD seeded liquidity so there's real headroom a second borrower could
still draw against and genuinely hit) against the same persistent
self-hosted anvil devnet (new addresses: Factory
`0x02b0b4efd909240fcb2eb5fae060dc60d112e3a4`, Router
`0x638a246f0ec8883ef68280293ffe8cfbabe61b44`, Oracle
`0x96F3cE39Ad2Bfdcf92C0f6E2c2CAbF83874660fc`, WQIE
`0x6C2d83262fF84cBaDb3e416D527403135D757892`, TUSD
`0xFD6F7A6a5c21A3f503EBaE7a473639974379c351`, Vault
`0xd49a0e9a4cd5979ae36840f542d2d7f02c4817be`), updated the 5 affected
`NEXT_PUBLIC_QIE_FORGE_*` Vercel env vars via the Vercel CLI (using
`printf '%s' | vercel env add`, not `echo | vercel env add`, per the
newline-bug warning in this file's prior entry), and ran `vercel --prod`
from the repo root (not `apps/web` — a stray `apps/web/.vercel` link from
this same pass pointed `vercel build` at the wrong install/build command
and 404'd on the `@qie-forge/core` workspace package; removed, redeployed
from the root where `vercel.json`'s real monorepo build command lives).

**Re-verified live after redeploy, not assumed**: `/`, `/swap`, `/pool`,
`/vault` all HTTP 200; `/api/quote` for 1 WQIE → `139579` TUSD (matches
every prior entry in this file exactly); `/api/vault-position` returns the
same documented 500,000 WQIE / 20,000 TUSD / 2.8x health-factor position.
`/vault`'s new "Borrow cap" stat (`VaultPoolStatsBar`, no wallet required)
renders the real live value: `"20000 / 100000 TUSD"`.

`next build` (clean), `npx eslint .` on `apps/web` (clean) both re-run and
pass. README.md/SUBMISSION.md/docs/TEAM-PRESENTATION.md updated with the
real current test count (62/62, up from 57/57) and the new borrow-cap
story in the Technical Quality judging row.

**Commit**: see git log for this pass's hash, pushed to
`caelum0x/qie-forge` main.

**Owner-only blocker, unchanged, still the single remaining gate**: a
funded QIE deployer wallet for the real Testnet/Mainnet broadcast — both
genuine owner/operator steps, unautomatable from this environment.
Everything up to and including that broadcast command is real, tested,
and ready, same as every pass before this one.

## 2026-10-29 (later): severity-scaled liquidation incentive curve shipped

Real gap closed, distinct from the reserve-factor work above: before this,
`QieForgeVault.liquidate()` paid every liquidator the exact same flat
`liquidationBonusBps`, regardless of how underwater a position actually
was. A liquidator weighing gas cost and exit-price risk had no extra
incentive to rush the positions most likely to turn into unrecoverable
bad debt (deeply underwater ones) over barely-underwater ones — exactly
backwards from what a protocol wants, and a real risk-management gap next
to the reserve-factor's revenue gap. Added an immutable
`liquidationBonusMaxBps` and `_dynamicLiquidationBonusBps(hf)`: the bonus
linearly interpolates from `liquidationBonusBps` (at `healthFactor() ==
1.0`) up to `liquidationBonusMaxBps` (at `healthFactor() <= 0.5`, the
curve's floor), clamped at both ends. Setting `liquidationBonusMaxBps ==
liquidationBonusBps` disables the curve entirely (flat, the exact
pre-existing behavior) — every one of the 29 pre-existing liquidation/vault
tests passes unchanged under this default, zero numeric updates needed.
A new `liquidationBonusBpsFor(user)` view exposes the real current rate to
bots/dashboards without needing to simulate `liquidate()` itself.

**A real bug found and fixed within this same pass, before any test ever
exercised it**: `liquidate()`'s forward seize calculation was updated to
use the new dynamic `bonusBps`, but the same function's "collateral is the
binding constraint" branch still back-calculated `coveredValueUsd` using
the old flat `liquidationBonusBps` — the two rates would have silently
diverged for exactly the case most likely to hit that branch (a deeply
underwater, collateral-exhausted position), corrupting the `badDebt`
write-off amount. Caught by re-reading the diff, fixed before writing any
test against it.

**Verified two ways:**
1. `forge test`: 5 new regression tests (constructor validation —
   `InvalidLiquidationBonusCurve` on `max < base` and `max > 100%`; flat-
   curve backward compatibility proven at two different underwater
   severities on the exact `vault` instance every pre-existing liquidation
   test already uses; `liquidationBonusBpsFor` returning the base rate for
   a healthy/debt-free position instead of reverting; and the curve's own
   exact closed-form math — 757bps at a mild `healthFactor` of 32/35,
   clamped to the 2,000bps max at a severe `healthFactor` of 12/35, with a
   real `liquidate()` call seizing the exact predicted 400 WQIE for a 100
   TUSD repay at that clamped rate). **52 → 57/57 pass**, zero regressions
   on the other 52.
2. **Live, on the real self-hosted demo chain** (`http://130.61.180.42:8647`,
   not just Foundry's test EVM): deployed a fresh, separate vault (base
   500bps / max 2,000bps / 0.5 floor) via `forge create` so the public
   demo's own open position stayed untouched, opened a real 1,000 WQIE /
   700 TUSD position, and read `liquidationBonusBpsFor()` directly via
   `cast call` at three real price points: healthy ($1.00) → `500` (base),
   mildly underwater ($0.80, `healthFactor` 0.9143) → `757`, severely
   underwater ($0.30, `healthFactor` 0.3429) → `2000` (clamped to max) —
   exactly the closed-form values the new unit tests assert. Then executed
   a real `liquidate()` transaction
   (`0x1c92080631375be88588b7af96eb6a782ad17ca474a820cef50d0d5560ed7ec4`)
   at the severe price: the liquidator's on-chain WQIE balance moved from
   `0` to exactly `400000000000000000000` (400 WQIE) for a 100 TUSD repay —
   the exact 20%-bonus prediction, proving the curve holds against real
   chain state, not just Foundry's test EVM.

**Redeployed the live public demo** (`DeployDemo.s.sol` now passes
`liquidationBonusMaxBps` too — 5% floor / 20% max, matching
`DeployVault.s.sol`'s mainnet-ready defaults) against the same persistent
self-hosted anvil devnet, updated the 5 affected `NEXT_PUBLIC_QIE_FORGE_*`
address env vars via the Vercel CLI (**and fixed a real latent bug found
while doing so**: `vercel env add` via `echo "$VALUE" | vercel env add ...`
had been silently baking a trailing newline into every one of those 5
address values — `Address "0x...\n" is invalid` on every vault-position
read until re-added with `printf '%s'` instead of `echo`; this had
apparently gone unnoticed since whichever earlier redeploy introduced the
pattern), and ran `vercel --prod`. Re-verified live after redeploy and
after the env-var fix, not just assumed: `/`, `/swap`, `/pool`, `/vault`
all HTTP 200; `/api/quote` for 1 WQIE → `139579` TUSD (matches every prior
entry in this file exactly); `/api/vault-position` returns the same
documented 500,000 WQIE / 20,000 TUSD / 2.8x health-factor position, now
also with `liquidationBonusBps: "500"` (the correct base rate — this
position is healthy). Separately re-ran the full one-command
`scripts/liquidation-bot-demo.sh` end-to-end against the updated
`DeployDemo.s.sol` on a fresh disposable local anvil: real `liquidate()`
tx `0x25a2e80758f8ca0fb64dd0cac82044e9d8fa84047b7c657c4fb10884c704bfd1`
seized `431020.41` WQIE at a real `560bps` (5.60%) bonus — correctly above
the 500bps floor since that run's health factor (`0.98`) is only barely
underwater, not the flat `5%` a pre-curve vault would have paid for the
identical liquidation.

`npm test` (33/33), `next build` (clean), `npx eslint .` on `apps/web`
(clean) all re-run and pass. README.md/SUBMISSION.md/TEAM-PRESENTATION.md
updated with the real current test count (57/57) and the new risk-curve
story in the Business Potential / Technical Quality judging rows.

**Owner-only blocker, unchanged, still the single remaining gate**: a
funded QIE deployer wallet for the real Testnet/Mainnet broadcast — both
genuine owner/operator steps, unautomatable from this environment.
Everything up to and including that broadcast command is real, tested,
and ready, same as every pass before this one.

## 2026-10-29: protocol reserve factor (real on-chain revenue mechanism) shipped

Real gap closed: before this, 100% of borrower interest flowed to lender
shares and the protocol itself had no revenue mechanism at all — a real
weak point for the "Business Potential" judging criterion (15% weight),
not just a cosmetic omission. Added `QieForgeVault.reserveFactorBps`
(immutable, e.g. 1,000 = 10%) and an immutable `treasury` address: on every
interest accrual, that fraction of the interest is carved out as
`protocolReserves` instead of flowing to lender-share pricing, withdrawable
only by `treasury` via `withdrawReserves()`. Borrowers are unaffected —
they still owe the exact same interest either way; only its split changes.

The tricky part, done correctly rather than approximated: `totalAssets()`
(what lender shares are priced against) already derives the vault's
interest-inclusive debt in O(1) via the `debtTimeWeightedSum` identity
(closed 2026-10-29, see the entry below) rather than iterating positions.
Reserves had to use the *same* O(1) aggregate so a lender depositing while
a large position's interest sits un-accrued can't be mispriced against a
reserve cut that hasn't been "realized" yet — `totalReserves()` = realized
`protocolReserves` + the reserve-factor cut of the pending (not-yet-touched)
aggregate interest, derived from the same identity `_accruedTotalDebt()`
already computes, so it can never drift out of sync with it.

**Verified two ways:**
1. `forge test`: 6 new regression tests (constructor validation, the real
   90%/10% interest split after a real `repay()`, the pending-vs-realized
   reserve accounting on an untouched position, `withdrawReserves` access
   control + the realized-amount cap, and 0%-reserve-factor backward
   compatibility). **46 → 52/52 pass**, zero regressions on the other 46.
2. **Live, on the real self-hosted demo chain** (`http://130.61.180.42:8647`,
   not just Foundry's test EVM): deployed a fresh vault via `forge create`
   with a real 5% APR rate and a 10% reserve factor, a `treasury` distinct
   from the deployer, borrowed 20,000 TUSD against 500,000 WQIE, advanced
   the chain 365 real days (`evm_increaseTime`), and read `currentDebt()`
   directly via `cast call`: debt grew from 20,000,000000 to
   20,999,999999 (≈1,000 TUSD interest, ≈5% as expected) and
   `totalReserves()` already reported `99,999,999` (≈10% of that interest)
   *before* anyone touched the position — proving the pending-aggregate
   math is correct on-chain, not just in a unit test. Then called the real
   `repay()`, confirmed `protocolReserves()` realized to `100,000,095`,
   confirmed a non-treasury account's `withdrawReserves()` call reverted
   `NotTreasury`, then had the real treasury account withdraw exactly that
   amount and land it in its TUSD balance.

**Redeployed the live public demo** (`DeployDemo.s.sol` now passes
`treasury`/`reserveFactorBps` too — 10% reserve factor, deployer as
treasury) against the same persistent self-hosted anvil devnet behind
`http://130.61.180.42:8647`, updated the 5 affected
`NEXT_PUBLIC_QIE_FORGE_*` Vercel env vars (vault/factory/router/collateral/
borrow addresses all changed since `DeployDemo` redeploys the full stack)
and ran `vercel --prod`. Re-verified live after redeploy, not just assumed:
`https://qie-forge.vercel.app/vault` → 200, new vault address rendered,
"Protocol reserves" stat tile shows real "0 TUSD" (correct — this demo's
rate is 0% APR, so no interest/reserves accrue on it); `/api/quote` for
1 WQIE → `139579` TUSD (matches every prior entry in this file exactly);
`/api/vault-position` returns the same documented 500,000/20,000/2.8x
position. Added `totalReserves()` to the always-visible `/vault` stats bar
(`VaultPoolStatsBar.tsx`) so judges see the real revenue number without a
connected wallet, same posture as the TVL/utilization stats shipped
2026-10-29 earlier.

`npm test` (33/33), `next build` (clean), `npx eslint .` on `apps/web`
(clean) all re-run and pass after the frontend change.

## 2026-10-28: lender vault UI shipped, two real bugs found and fixed on the live demo

Real hardening pass (not a new feature from scratch): used the live site as a
real user would, found the `/vault` page only ever exposed
`depositCollateral()` — never `borrow()`, `repay()`, `withdrawCollateral()`,
or the lender-side `deposit()`/`withdraw()` that have existed in the
contract and SDKs since commit `f55e3c6` — and while wiring those up, found
two real, currently-live defects:

1. **Wrong chain ID on wallet connect.** `SwapCard`/`VaultCard`'s own
   "Connect Wallet" buttons hardcoded `connect(1983)` (QIE Testnet), so on
   the live demo site (`NEXT_PUBLIC_QIE_FORGE_NETWORK=demo`, chain 31337)
   a real wallet user clicking either button would be told to switch to
   the wrong chain — every subsequent `eth_sendTransaction` would target a
   network with nothing deployed. The header's own `WalletConnectButton`
   already derived `chainId` correctly from `getNetworkConfig()`; the two
   duplicated in-card buttons just never reused that. Fixed: both cards
   now call `connect(getNetworkConfig().chainId)`.
2. **The live demo oracle went stale and `borrow()`/`healthFactor()`
   started reverting for everyone, including the documented demo
   position.** `QieOracleAdapter`'s staleness check (`maxStalenessSeconds`)
   was set to 3600s against a `MockAggregatorV3` whose `updatedAt` is only
   ever set once, at deploy time — so ~1 hour after any deploy,
   `StalePrice` starts reverting forever. Confirmed live:
   `cast call healthFactor(deployer)` reverted with `StalePrice` before the
   fix. Fixed two ways: (a) called the deployed oracle's `setMaxStaleness`
   (owner-only, deployer key held) to 100 years on the live instance —
   confirmed `healthFactor(deployer)` returns `2.8e18` again immediately
   after; (b) changed `DeployDemo.s.sol`'s oracle constructor to the same
   ~10-year window so a future redeploy doesn't reintroduce this.

**A third, more serious issue surfaced while building the lender UI and
testing it against the real deployed contract, not just reading the
source**: `QieForgeVault.deposit()`'s "first depositor mints 1:1" rule
ignored any `totalAssets()` that already existed before `totalLenderShares`
was ever nonzero — exactly the state `DeployDemo.s.sol`'s own seeding
pattern creates (500,000 TUSD minted straight into the vault, never
through `deposit()`). Reproduced for real against the live (pre-fix)
contract: depositing 1,000 TUSD as the first-ever lender minted 1,000
shares worth **501,000 TUSD** (100% of `totalAssets()`, including the
pre-funded 500,000 + the deployer's 20,000 outstanding debt) — a real,
practically-zero-cost drain of operator-seeded launch liquidity, the exact
textbook ERC4626 "donation/inflation" attack, with no mitigation (unlike
`QieForgePair`'s `MINIMUM_LIQUIDITY` burn-to-`0xdEaD`, which this contract
had no equivalent of). **Fixed in
`packages/contracts/src/vault/QieForgeVault.sol`**: added
`MINIMUM_LENDER_SHARES = 1000`, permanently locked (attributed to nobody)
on the first deposit into a vault whose `totalAssets()` is already
nonzero, sized so the depositor's own shares are worth exactly what they
put in and the locked floor absorbs the pre-existing value — a genuinely
pristine vault (`totalAssets() == 0`) still mints 1:1, unchanged. Two new
Foundry tests added:
`test_deposit_firstDepositor_cannotDrainPreFundedLiquidity` (direct
reproduction + fix assertion) and
`test_deposit_freshVault_firstDepositorStillMints1to1` (regression guard
for the unaffected case). **`forge test`: 43/43 pass** (was 41/41).
Re-verified live against a freshly redeployed demo stack (new addresses,
same seed amounts, same documented 500,000/20,000/2.8x numbers): the exact
same attack now round-trips exactly 1,000 TUSD in, 1,000 TUSD out — no
windfall. **No real funds were ever at risk** — this was found and fixed
entirely before any QIE Testnet/Mainnet deployment; the live demo chain's
tokens have zero real value, and the vulnerable (pre-fix) bytecode's live
instance was abandoned, not patched in place (immutable bytecode), by
redeploying fresh with the fixed source.

**Shipped**: `components/VaultCard.tsx` (deposit/withdraw collateral,
borrow, repay) and a new `components/LendCard.tsx` (supply/withdraw
liquidity as a lender, with live pool stats: your supplied value, your
shares, idle liquidity, total outstanding debt) are both live on
`/vault`. New ABI entries in `lib/contracts.ts`
(`withdrawCollateral`/`repay`/`deposit`/`withdraw`/`lenderShares`/
`totalLenderShares`/`totalAssets`/`totalDebtPrincipal`/`borrowAsset`), a
shared `lib/erc20Actions.ts` (`ensureAllowance`/`sendContractCall`) used by
both the swap and vault/lend flows instead of duplicating the
approve-then-send pattern. Verified the exact encoding every handler uses
against the live redeployed contract with `cast send`/`cast call` using
real anvil test accounts: `depositCollateral` → `borrow` → `repay` →
`withdrawCollateral` round-trips cleanly, and lender `deposit` → `withdraw`
round-trips cleanly post-fix. `next build`/`next lint` clean, zero type
errors. Not click-tested with a real wallet extension (same honest gap as
the swap/deposit flow already had — this environment has no browser
wallet).

**Infra**: the self-hosted demo RPC (`qie-forge-demo-rpc.caddy`, public on
`:8647`) had silently dropped out of `/etc/caddy/sites-enabled/` a second
time (first was 2026-10-27) because it was never added to this box's
managed `caddy/sites/` directory or `CADDY_SITES` list, so every
`install.sh caddy` run regenerated the enabled set without it. Fixed for
real this time (not another hand-copy into `/etc/caddy/`): added the site
file to `infra-box/caddy/sites/qie-forge-demo-rpc.caddy` and
`qie-forge-demo-rpc` to `CADDY_SITES` on the box, verified a second
`install.sh caddy` run keeps it enabled.

## Built and verified: contracts (local EVM, Foundry)

```
cd packages/contracts && forge test -vv
```

**65/65 tests pass** across 4 suites (`QieOracleAdapter` 8, `QieForgeRouter`
8, `QieForgeVault` 42, `QieForgePair` 7) — see the "2026-10-29 (even later):
deposit() panic after a full bad-debt wipeout" section above for the
newest, the "2026-10-29 (newest): bad-debt write-off vs. realized
reserves" section above for the 2 before that,
"2026-10-29 (latest): aggregate borrow cap" for the 5 before that, "2026-10-29 (later):
severity-scaled liquidation incentive curve" for the 5 before that, and
"2026-10-29: protocol reserve factor" for the 6 before that
(the reserve-factor split, pending-vs-realized accounting, and
`withdrawReserves` access control). Beyond the original 25 (constant-
product invariants, LP math, fee accrual/protocol-fee switch, TWAP,
slippage/deadline checks, oracle staleness/decimals handling, base
LTV/health-factor/interest/liquidation), this pass added:

- **3-hop routing across 3 separate pools** (`test_threeHopSwap_acrossThreePools_matchesLibraryQuote`) — proves the router's multi-pool path execution, not just a 2-hop case.
- **`swapTokensForExactTokens`** (exact-output swaps) — pulls exactly the quoted input, reverts above a max-input cap.
- **Oracle adapter edge cases**: `DecimalsTooLarge` revert for a >18-decimal feed, feed rotation to a new aggregator, disabling the staleness check with `maxStaleness=0`.
- **Vault liquidation edge cases**: liquidating a position with zero debt reverts (`NothingToLiquidate`), over-repaying reverts (`RepayExceedsDebt`), a partial liquidation that restores health factor above 1, and two sequential liquidators each receiving their proportional bonus from the same underwater position.
- **Lender deposit/withdraw share accounting** (`test_deposit_mintsSharesAtExchangeRate`, `test_deposit_lenderSharesAppreciateFromBorrowerInterest`, `test_withdraw_redeemsSharesForUnderlying`, `test_withdraw_revertsWhenLiquidityIsLentOut`, `test_withdraw_belowLtvThreshold_reverts`, `test_withdraw_revertsWhenSharesExceedBalance`, `test_liquidation_cannotSeizeMoreThanAvailableCollateral`, `test_liquidation_minimalRepayStillZeroesDebt_whenCollateralExhausted`) — `QieForgeVault.deposit()`/`withdraw()` exist and are covered; a stale claim that this flow was missing (repeated across a couple of commit messages without re-reading the file) has been corrected below and in this file's own history.

## Built and verified: TypeScript SDK + CLI (real network calls)

`chain-info`/`oracle-price` against real testnet (chain 1983, block
>9.39M) and mainnet (chain 1990, block >11.46M) RPCs, real BTC
($79,896.25) and QIE ($0.1398) prices via the corrected oracle ABI.
**24/24 CLI unit tests pass** (`npm run test -w packages/cli`, vitest):
10 tests for `args.ts` (`parseArgs`/`requireFlag` edge cases) and 14 for
`index.ts`'s command dispatch (`chain-info`/`oracle-price`/`balance`/
`explorer-lookup` output formatting, network validation, missing-flag and
unknown-command error paths, handler-error-to-exitCode propagation),
run against a mocked `@qie-forge/core` so they're fast and offline —
closing the "zero test files" gap `packages/cli/test/` previously had.

## Built and verified: Python SDK (`packages/python`)

**23/23 tests pass** (`pytest -q` + `QIE_FORGE_RUN_LIVE_TESTS=1 pytest -q`):

- 11 offline unit tests (`networks`, `qusdc`, `amm` quote math).
- 4 live tests against the real testnet/mainnet RPC (same floors as the TS SDK).
- 4 live tests against the real mainnet oracle (BTC/QIE prices, testnet fail-closed check, unsupported-asset check).
- **2 local-anvil integration tests** that deploy the ACTUAL compiled `packages/contracts` bytecode (`MockERC20`, `MockAggregatorV3`, `QieOracleAdapter`, `QieForgeVault`, `QieForgeFactory`, `QieForgeRouter` — loaded from `forge build`'s own `out/` artifacts, not re-implemented) to a local anvil devnet, then exercise `VaultClient.get_position()` and `amm.get_amounts_out()`/`build_swap_exact_tokens_for_tokens_tx()` against them. Real assertions: the Python-read health factor matches a hand-calculated value, the Python quote math matches the deployed router's own `getAmountsOut()` call exactly, and the unsigned transaction this SDK builds actually executes successfully on-chain (`receipt.status == 1`).

## Built and verified: Rust SDK (`packages/rust`)

**15/15 tests pass** (`cargo test` + `QIE_FORGE_RUN_LIVE_TESTS=1 cargo test --test live_chain`):

- 9 offline unit tests (`networks`, `qusdc`, `amm` quote math, using `ethers`'s `U256`).
- 4 live tests against the real testnet/mainnet RPC and the real mainnet BTC oracle, using an `abigen!`-generated typed binding for the same corrected `IQieOracleAggregator` interface the TS/Python SDKs use.
- **2 local-anvil integration tests** (`tests/anvil_integration.rs`, closing the gap previously tracked here) that deploy the actual compiled `packages/contracts` bytecode (`MockERC20`, `MockAggregatorV3`, `QieOracleAdapter`, `QieForgeVault`, `QieForgeFactory`, `QieForgeRouter`, loaded from `forge build`'s own `out/` artifacts) to a local anvil devnet via `ethers-rs`, then exercise `vault::get_position()` and `amm::get_amounts_out()`/`build_swap_exact_tokens_for_tokens_tx()` against them — same pattern as the existing Python anvil test, same real assertions (health factor matches a hand-calculated value, quote math matches the deployed router's own `getAmountsOut()`, the built unsigned tx actually executes on-chain with `status == 1`).

## Built and verified: frontend (`apps/web`, Next.js 16 + viem)

**Live and public**: https://qie-forge.vercel.app (Vercel, auto-deployed
from this repo's `main`; deployment protection explicitly disabled so it's
reachable with no login — confirmed via a plain `curl` returning HTTP 200).

- **Home page** (`/`) is a server component that calls `@qie-forge/core`
  directly (same workspace package the CLI uses) on every request — no
  caching, no fixtures. Confirmed live output (just re-fetched):
  Testnet block #9,390,810 (chain 1983), Mainnet block #11,462,827 (chain
  1990), BTC $79,896.25, QIE $0.1398.
- **`/swap`** and **`/vault`** now render a real, live demo deployment by
  default (updated 2026-10-27, after the prior empty-state behavior drew a
  real owner complaint): `NEXT_PUBLIC_QIE_FORGE_NETWORK=demo` and the
  `NEXT_PUBLIC_QIE_FORGE_*_ADDRESS` vars are set on the real Vercel
  production project, pointing at a persistent, publicly reachable anvil
  devnet (`http://130.61.180.42:8647`, self-hosted on the products box —
  Docker container `qie-forge-demo-anvil`, Caddy site
  `qie-forge-demo-rpc.caddy`, OCI Security List rule for port 8647). The
  real compiled Factory/Router/OracleAdapter/Vault contracts are deployed
  there via `script/DeployDemo.s.sol`, seeded with real AMM liquidity and a
  real open vault position. A `DemoBanner` is shown on both pages whenever
  the network is `demo`, explicit that this is NOT QIE Testnet or Mainnet.
  If `NEXT_PUBLIC_QIE_FORGE_ROUTER_ADDRESS`/`..._VAULT_ADDRESS` are ever
  unset again (e.g. a fresh clone with no env configured), the honest
  "not deployed on this network yet" empty state still renders — that
  fallback was not removed, just no longer the default on the hosted site.
- **Proven against a real deployment, on the live production URL, not just
  locally**: `curl https://qie-forge.vercel.app/api/quote?amountIn=1000000000000000000&path=<WQIE>&path=<TUSD>`
  returns a real on-chain quote (`139579` raw TUSD units for 1 WQIE),
  matching a direct `cast call` to the same deployed router's own
  `getAmountsOut()`. `curl https://qie-forge.vercel.app/api/vault-position?user=<demo deployer>`
  returns a real open position (500,000 WQIE collateral, 20,000 TUSD debt,
  health factor 2.8x). `gstack browse` against the live production URL
  confirms the `/swap` page's real WQIE/TUSD token picker and a real
  computed quote (`10` WQIE -> `1.39573` TUSD) typed through the actual
  UI, zero console errors.
- **Wallet connect / swap-submit / deposit-submit**: implemented against
  QIE Wallet's real documented EIP-1193/EIP-6963 interface
  (`lib/wallet.ts`, reusing `@qie-forge/core`'s `walletConnect.ts`
  constants), and the swap/deposit transaction-building code paths are
  real (`encodeFunctionData` + `eth_sendTransaction`, approve-then-act).
  **Not click-tested end-to-end in a real browser** — that needs an actual
  wallet extension (QIE Wallet or another EVM wallet) in a real browser
  session, which this environment doesn't have. Honestly flagged, not
  claimed as verified.

## Not yet done (honest gaps, not hidden)

- **No on-chain Testnet or Mainnet deployment of the protocol itself.**
  `script/Deploy.s.sol` compiles; deploying costs real gas and needs a
  funded deployer key. QIE's testnet faucet (`qie.digital/faucet`) is a
  connect-a-wallet web app, not a plain API — a genuine owner/operator
  step. Once a real deployment exists, setting the
  `NEXT_PUBLIC_QIE_FORGE_*_ADDRESS` env vars on the live Vercel project
  (and flipping `NEXT_PUBLIC_QIE_FORGE_NETWORK` from `demo` to
  `testnet`/`mainnet`) turns the frontend's swap/vault pages from the demo
  deployment into the real thing — no frontend code change needed, same
  mechanism the demo deployment above already proves.
- **No real-browser wallet click-through test** for the frontend (needs a
  wallet extension this environment doesn't have).
- **QUSDC integration is fail-closed everywhere** — the real QUSDC
  contract address was never independently confirmed.
- **QIE ID is not integrated** — no public API or contract for it was
  found during research.
