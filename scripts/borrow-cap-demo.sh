#!/usr/bin/env bash
# QIE Forge — one-command borrow-cap demo.
#
# Spins up a disposable local anvil devnet, deploys the REAL compiled
# QieForgeFactory/Router/OracleAdapter/Vault bytecode to it via
# script/DeployDemo.s.sol (the same script backing the live demo
# frontend, which sets a real, nonzero QieForgeVault.borrowCap of
# 100,000 TUSD — see DeployDemo.s.sol's DEMO_BORROW_CAP), then proves
# the cap live against that exact deployed bytecode:
#   1. A borrow() landing EXACTLY on the remaining cap headroom succeeds.
#   2. The very next borrow() (even 1 unit over) reverts with the real
#      BorrowCapExceeded custom error.
#   3. totalDebtPrincipal never moves on the reverted call.
#
# Not a unit test against Foundry's test EVM -- this exercises the exact
# bytecode the live demo frontend reads, the same posture every other
# *-demo.sh script in this repo uses.
#
# Usage:
#   ./scripts/borrow-cap-demo.sh
#
# Requires: foundry (anvil, forge, cast) on PATH.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
CONTRACTS_DIR="$REPO_ROOT/packages/contracts"
PORT=8648
RPC_URL="http://127.0.0.1:${PORT}"
ANVIL_LOG="$(mktemp -t qie-forge-anvil-borrowcap-demo)"
DEPLOY_LOG="$(mktemp -t qie-forge-deploy-borrowcap-demo)"

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
  rm -f "$ANVIL_LOG" "$DEPLOY_LOG"
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
if [[ -z "$DEPLOYER_KEY" || -z "$DEPLOYER_ADDR" ]]; then
  echo "ERROR: could not parse anvil's default account from its startup log." >&2
  cat "$ANVIL_LOG" >&2
  exit 1
fi

echo "== 2. Deploying the real QIE Forge demo stack (factory/router/oracle/vault) =="
(
  cd "$CONTRACTS_DIR"
  DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY" forge script script/DeployDemo.s.sol:DeployDemo \
    --rpc-url "$RPC_URL" --broadcast --private-key "$DEPLOYER_KEY" -vv
) | tee "$DEPLOY_LOG"

VAULT_ADDR="$(grep -E '^\s*Vault:' "$DEPLOY_LOG" | awk '{print $NF}' | tail -1)"
WQIE_ADDR="$(grep -E '^\s*WQIE:' "$DEPLOY_LOG" | awk '{print $NF}' | tail -1)"
for addr_name in "VAULT_ADDR:$VAULT_ADDR" "WQIE_ADDR:$WQIE_ADDR"; do
  value="${addr_name#*:}"
  if [[ -z "$value" || ! "$value" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: failed to parse a deployed address (${addr_name}) from forge script output." >&2
    exit 1
  fi
done

echo
echo "== 2b. Depositing extra WQIE collateral so the borrow cap -- not LTV -- is the"
echo "       binding constraint being proven here (same real depositCollateral() path"
echo "       any real user takes) =="
cast send "$WQIE_ADDR" "mint(address,uint256)" "$DEPLOYER_ADDR" 5000000000000000000000000 \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$WQIE_ADDR" "approve(address,uint256)" "$VAULT_ADDR" 5000000000000000000000000 \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null
cast send "$VAULT_ADDR" "depositCollateral(uint256)" 5000000000000000000000000 \
  --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" > /dev/null

echo
echo "== 3. Reading the real deployed borrowCap and totalDebtPrincipal =="
BORROW_CAP="$(cast call "$VAULT_ADDR" "borrowCap()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
TOTAL_DEBT="$(cast call "$VAULT_ADDR" "totalDebtPrincipal()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
echo "borrowCap:            $BORROW_CAP"
echo "totalDebtPrincipal:   $TOTAL_DEBT (the demo's own pre-opened position)"

HEADROOM=$((BORROW_CAP - TOTAL_DEBT))
echo "headroom remaining:   $HEADROOM"

echo
echo "== 4. borrow() exactly up to the remaining headroom -- must SUCCEED =="
cast send "$VAULT_ADDR" "borrow(uint256)" "$HEADROOM" --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" \
  | grep -E "status|transactionHash"

NEW_TOTAL_DEBT="$(cast call "$VAULT_ADDR" "totalDebtPrincipal()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
echo "totalDebtPrincipal now: $NEW_TOTAL_DEBT (must equal borrowCap: $BORROW_CAP)"
if [[ "$NEW_TOTAL_DEBT" != "$BORROW_CAP" ]]; then
  echo "ERROR: totalDebtPrincipal does not equal borrowCap after landing exactly on it." >&2
  exit 1
fi

echo
echo "== 5. borrow(1) -- 1 unit over the cap -- must REVERT with BorrowCapExceeded =="
set +e
REVERT_OUTPUT="$(cast send "$VAULT_ADDR" "borrow(uint256)" 1 --rpc-url "$RPC_URL" --private-key "$DEPLOYER_KEY" 2>&1)"
REVERT_STATUS=$?
set -e
echo "$REVERT_OUTPUT"
if [[ $REVERT_STATUS -eq 0 ]] || ! echo "$REVERT_OUTPUT" | grep -q "BorrowCapExceeded"; then
  echo "ERROR: expected borrow(1) to revert with BorrowCapExceeded, it did not." >&2
  exit 1
fi

FINAL_TOTAL_DEBT="$(cast call "$VAULT_ADDR" "totalDebtPrincipal()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')"
echo
echo "totalDebtPrincipal unchanged by the reverted call: $FINAL_TOTAL_DEBT"
if [[ "$FINAL_TOTAL_DEBT" != "$BORROW_CAP" ]]; then
  echo "ERROR: totalDebtPrincipal moved despite the revert." >&2
  exit 1
fi

echo
echo "== DONE: real on-chain proof, against real deployed bytecode =="
echo "  - landed exactly on borrowCap ($BORROW_CAP): succeeded"
echo "  - 1 unit over: reverted with BorrowCapExceeded, state unchanged"
