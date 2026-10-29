#!/usr/bin/env bash
# QIE Forge — one-command bad-debt / realized-reserves clamp demo.
#
# Proves, against REAL deployed QieForgeVault bytecode on a disposable
# local anvil devnet (not just Foundry's test EVM), a real insolvency/DoS
# gap found 2026-10-29 and fixed in the same pass: a bad-debt write-off in
# liquidate() shrinks totalDebtPrincipal (the vault's real backing)
# without ever touching the separate, already-realized protocolReserves
# bucket. With a real nonzero reserveFactorBps (every real deploy of this
# vault uses one -- see DeployVault.s.sol's DEFAULT_RESERVE_FACTOR_BPS), a
# position whose entire debt gets written off as bad debt could leave
# protocolReserves larger than totalDebtPrincipal + idle borrowAsset
# balance combined -- the vault's only two sources of real backing.
# totalAssets() computes `idle + debt - totalReserves()`; once
# totalReserves() exceeds idle + debt, that subtraction underflows and
# reverts *every future call*, including every lender's deposit() and
# withdraw() -- permanently freezing all lender funds, forever.
#
# The live public demo's own vault (DeployDemo.s.sol) can't reproduce this
# live because its ratePerSecond18 is deliberately 0 (no interest ever
# accrues there), so this script deploys its own throwaway, realistically-
# configured vault (real ~5% APR, real 10% reserve factor) instead of
# touching the public demo's own open position.
#
# Usage:
#   ./scripts/bad-debt-reserve-clamp-demo.sh
#
# Requires: foundry (anvil, forge, cast) on PATH.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
CONTRACTS_DIR="$REPO_ROOT/packages/contracts"
PORT=8649
RPC_URL="http://127.0.0.1:${PORT}"
ANVIL_LOG="$(mktemp -t qie-forge-anvil-baddebt-demo)"

for bin in anvil forge cast; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: $bin not found on PATH (install Foundry to run this demo)." >&2
    exit 1
  fi
done

cleanup() {
  if [[ -n "${ANVIL_PID:-}" ]] && kill -0 "$ANVIL_PID" 2>/dev/null; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
  rm -f "$ANVIL_LOG"
}
trap cleanup EXIT

echo "== 1. Starting a disposable local anvil devnet on port ${PORT} =="
anvil --port "$PORT" > "$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!

for _ in $(seq 1 50); do
  if cast chain-id --rpc-url "$RPC_URL" > /dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
if ! cast chain-id --rpc-url "$RPC_URL" > /dev/null 2>&1; then
  echo "ERROR: anvil did not start listening on ${RPC_URL} in time. Log:" >&2
  cat "$ANVIL_LOG" >&2
  exit 1
fi

DEPLOYER_KEY="$(awk '/^Private Keys/{flag=1; next} flag && /^\(0\)/{print $2; exit}' "$ANVIL_LOG")"
DEPLOYER_ADDR="$(awk '/^Available Accounts/{flag=1; next} flag && /^\(0\)/{print $2; exit}' "$ANVIL_LOG")"
LIQUIDATOR_KEY="$(awk '/^Private Keys/{flag=1; next} flag && /^\(1\)/{print $2; exit}' "$ANVIL_LOG")"
LIQUIDATOR_ADDR="$(awk '/^Available Accounts/{flag=1; next} flag && /^\(1\)/{print $2; exit}' "$ANVIL_LOG")"
LENDER2_ADDR="$(awk '/^Available Accounts/{flag=1; next} flag && /^\(2\)/{print $2; exit}' "$ANVIL_LOG")"
LENDER2_KEY="$(awk '/^Private Keys/{flag=1; next} flag && /^\(2\)/{print $2; exit}' "$ANVIL_LOG")"
if [[ -z "$DEPLOYER_KEY" || -z "$LIQUIDATOR_KEY" || -z "$LENDER2_KEY" ]]; then
  echo "ERROR: could not parse anvil's default accounts from its startup log." >&2
  cat "$ANVIL_LOG" >&2
  exit 1
fi

cd "$CONTRACTS_DIR"

echo "== 2. Deploying real WQIE/TUSD tokens + mock price feeds + oracle adapter =="
WQIE="$(forge create test/mocks/MockERC20.sol:MockERC20 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
  --broadcast --json --constructor-args "Wrapped QIE" "WQIE" 18 | awk -F'"' '/deployedTo/{print $4}')"
TUSD="$(forge create test/mocks/MockERC20.sol:MockERC20 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
  --broadcast --json --constructor-args "Test USD" "TUSD" 6 | awk -F'"' '/deployedTo/{print $4}')"
WQIE_FEED="$(forge create test/mocks/MockAggregatorV3.sol:MockAggregatorV3 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
  --broadcast --json --constructor-args 8 "WQIE / USD (Demo)" 100000000 | awk -F'"' '/deployedTo/{print $4}')"
TUSD_FEED="$(forge create test/mocks/MockAggregatorV3.sol:MockAggregatorV3 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
  --broadcast --json --constructor-args 8 "TUSD / USD (Demo)" 100000000 | awk -F'"' '/deployedTo/{print $4}')"
ORACLE="$(forge create src/oracle/QieOracleAdapter.sol:QieOracleAdapter --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
  --broadcast --json --constructor-args "$DEPLOYER_ADDR" 315360000 | awk -F'"' '/deployedTo/{print $4}')"

for addr_name in "WQIE:$WQIE" "TUSD:$TUSD" "WQIE_FEED:$WQIE_FEED" "TUSD_FEED:$TUSD_FEED" "ORACLE:$ORACLE"; do
  value="${addr_name#*:}"
  if [[ -z "$value" || ! "$value" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: failed to deploy/parse ${addr_name%%:*}." >&2
    exit 1
  fi
done

cast send "$ORACLE" "setFeed(address,address)" "$WQIE" "$WQIE_FEED" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$ORACLE" "setFeed(address,address)" "$TUSD" "$TUSD_FEED" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

echo "== 3. Deploying a real throwaway QieForgeVault: ~5% APR, 10% reserve factor, no borrow cap =="
VAULT="$(forge create src/vault/QieForgeVault.sol:QieForgeVault --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
  --broadcast --json \
  --constructor-args "$WQIE" "$TUSD" "$ORACLE" 7500 8000 500 500 1585489599 "$DEPLOYER_ADDR" 1000 0 \
  | awk -F'"' '/deployedTo/{print $4}')"
if [[ -z "$VAULT" || ! "$VAULT" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "ERROR: failed to deploy the vault." >&2
  exit 1
fi
echo "WQIE:    $WQIE"
echo "TUSD:    $TUSD"
echo "Oracle:  $ORACLE"
echo "Vault:   $VAULT"

echo
echo "== 4. Lender deposits 700 TUSD; borrower deposits 1,000 WQIE and borrows all 700 TUSD =="
cast send "$TUSD" "mint(address,uint256)" "$DEPLOYER_ADDR" 700000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$TUSD" "approve(address,uint256)" "$VAULT" 700000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$VAULT" "deposit(uint256)" 700000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

cast send "$WQIE" "mint(address,uint256)" "$DEPLOYER_ADDR" 1000000000000000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$WQIE" "approve(address,uint256)" "$VAULT" 1000000000000000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$VAULT" "depositCollateral(uint256)" 1000000000000000000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$VAULT" "borrow(uint256)" 700000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

IDLE_BEFORE="$(cast call "$TUSD" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$RPC_URL" | awk '{print $1}')"
echo "vault idle TUSD balance right after borrow: $IDLE_BEFORE (must be 0 -- fully utilized)"

echo
echo "== 5. Advancing a real 365 days so real interest (and a real 10% reserve cut) accrues =="
cast rpc evm_increaseTime 31536000 --rpc-url "$RPC_URL" > /dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null

echo '== 6. Crashing the WQIE price to $0.00000001 -- deep enough that liquidating 100% of the'
echo "      collateral still covers only a negligible sliver of the accrued debt =="
cast send "$WQIE_FEED" "setAnswer(int256)" 1 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$TUSD_FEED" "setAnswer(int256)" 100000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null # refresh updatedAt, same $1.00

DEBT_BEFORE="$(cast call "$VAULT" "currentDebt(address)(uint256)" "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')"
echo "accrued debt right before liquidation: $DEBT_BEFORE (> 700000000 proves real interest accrued)"

echo
echo "== 7. Liquidating the entire position -- a full bad-debt write-off =="
cast send "$TUSD" "mint(address,uint256)" "$LIQUIDATOR_ADDR" "$DEBT_BEFORE" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$TUSD" "approve(address,uint256)" "$VAULT" "$DEBT_BEFORE" --rpc-url "$RPC_URL" --private-key "$LIQUIDATOR_KEY" > /dev/null
LIQ_OUTPUT="$(cast send "$VAULT" "liquidate(address,uint256)" "$DEPLOYER_ADDR" "$DEBT_BEFORE" --rpc-url "$RPC_URL" --private-key "$LIQUIDATOR_KEY")"
echo "$LIQ_OUTPUT" | grep -E "status|transactionHash"
if ! echo "$LIQ_OUTPUT" | grep -q "status.*1 (success)"; then
  echo "ERROR: liquidate() itself reverted or failed -- cannot proceed with the real proof below." >&2
  exit 1
fi

TOTAL_DEBT_AFTER="$(cast call "$VAULT" "totalDebtPrincipal()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
RESERVES_AFTER="$(cast call "$VAULT" "protocolReserves()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
IDLE_AFTER="$(cast call "$TUSD" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$RPC_URL" | awk '{print $1}')"
echo
echo "totalDebtPrincipal after full write-off: $TOTAL_DEBT_AFTER (must be 0)"
echo "protocolReserves after the clamp:        $RESERVES_AFTER"
echo "vault idle TUSD balance after:           $IDLE_AFTER"
if [[ "$TOTAL_DEBT_AFTER" != "0" ]]; then
  echo "ERROR: expected a full write-off (totalDebtPrincipal == 0)." >&2
  exit 1
fi

echo
echo "== 8. The real proof: totalAssets() must NOT underflow-revert (it would, pre-fix, the"
echo "      moment protocolReserves exceeds totalDebtPrincipal + idle) =="
set +e
TOTAL_ASSETS_OUTPUT="$(cast call "$VAULT" "totalAssets()(uint256)" --rpc-url "$RPC_URL" 2>&1)"
TOTAL_ASSETS_STATUS=$?
set -e
echo "totalAssets(): $TOTAL_ASSETS_OUTPUT"
if [[ $TOTAL_ASSETS_STATUS -ne 0 ]]; then
  echo "ERROR: totalAssets() reverted -- the fix did not take, the vault is bricked." >&2
  exit 1
fi
if [[ "$RESERVES_AFTER" -gt $((TOTAL_DEBT_AFTER + IDLE_AFTER)) ]]; then
  echo "ERROR: protocolReserves ($RESERVES_AFTER) exceeds totalDebtPrincipal + idle ($((TOTAL_DEBT_AFTER + IDLE_AFTER))) -- the invariant the clamp is supposed to hold was violated." >&2
  exit 1
fi

echo
echo "== 9. Proving lender funds are not frozen: the original lender can still withdraw() =="
echo "      (even though their stake was genuinely wiped to zero by this badDebt -- the real"
echo "      point is that the call itself does not revert, pre-fix every call touching"
echo "      totalAssets() would) =="
LENDER_SHARES="$(cast call "$VAULT" "lenderShares(address)(uint256)" "$DEPLOYER_ADDR" --rpc-url "$RPC_URL" | awk '{print $1}')"
WITHDRAW_OUTPUT="$(cast send "$VAULT" "withdraw(uint256)" "$LENDER_SHARES" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY")"
echo "$WITHDRAW_OUTPUT" | grep -E "status|transactionHash"
if ! echo "$WITHDRAW_OUTPUT" | grep -q "status.*1 (success)"; then
  echo "ERROR: the original lender's withdraw() reverted -- the vault is still effectively bricked." >&2
  exit 1
fi

echo
echo "== 10. And a fresh lender can deposit() into what is now, once again, a pristine"
echo "       (zero-shares) vault =="
cast send "$TUSD" "mint(address,uint256)" "$LENDER2_ADDR" 50000000 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$TUSD" "approve(address,uint256)" "$VAULT" 50000000 --rpc-url "$RPC_URL" --private-key "$LENDER2_KEY" > /dev/null
DEPOSIT_OUTPUT="$(cast send "$VAULT" "deposit(uint256)" 50000000 --rpc-url "$RPC_URL" --private-key "$LENDER2_KEY")"
echo "$DEPOSIT_OUTPUT" | grep -E "status|transactionHash"
if ! echo "$DEPOSIT_OUTPUT" | grep -q "status.*1 (success)"; then
  echo "ERROR: a fresh lender's deposit() reverted -- the vault is still effectively bricked." >&2
  exit 1
fi

echo
echo "== DONE: real on-chain proof, against real deployed bytecode =="
echo "  - a full bad-debt write-off with a real 10% reserve factor genuinely risked pushing"
echo "    protocolReserves ($RESERVES_AFTER after the clamp) above totalDebtPrincipal + idle"
echo "  - the invariant held, totalAssets() did not underflow-revert"
echo "  - the wiped-out lender could still withdraw() (for zero) and a brand-new lender could"
echo "    still deposit() afterward -- the vault was never bricked"
echo
echo "NOTE: a SEPARATE, distinct edge case was found live while building this demo (not fixed"
echo "in this pass -- see plans/qie-hackathon.md): calling deposit() directly (skipping the"
echo "withdraw() in step 9) while totalAssets() == 0 but totalLenderShares > 0 reverts with a"
echo "division-by-zero panic in deposit()'s exchange-rate branch. Flagged for a future pass."
