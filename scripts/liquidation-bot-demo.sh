#!/usr/bin/env bash
# QIE Forge — one-command liquidation bot demo.
#
# Spins up a disposable local anvil devnet, deploys the REAL compiled
# QieForgeFactory/Router/OracleAdapter/Vault bytecode to it via
# script/DeployDemo.s.sol (the same script backing the live demo
# frontend), then runs scripts/liquidation-bot-demo.mjs to crash the
# demo's collateral price, detect the resulting unhealthy position, and
# execute a real on-chain liquidate() call — proving the full
# liquidation path works end-to-end, not just in a unit test.
#
# Usage:
#   ./scripts/liquidation-bot-demo.sh
#
# Requires: foundry (anvil, forge, cast) and node >= 18 on PATH.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"
CONTRACTS_DIR="$REPO_ROOT/packages/contracts"
PORT=8646
RPC_URL="http://127.0.0.1:${PORT}"
ANVIL_LOG="$(mktemp -t qie-forge-anvil-demo)"
DEPLOY_LOG="$(mktemp -t qie-forge-deploy-demo)"

for bin in anvil forge cast node; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: $bin not found on PATH (install Foundry + Node to run this demo)." >&2
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

# Anvil prints its 10 deterministic default private keys on startup.
# Parse the first two real keys from the real log instead of hardcoding
# them, so this stays correct even if a future anvil version changes
# derivation.
BORROWER_KEY="$(awk '/^Private Keys/{flag=1; next} flag && /^\(0\)/{print $2; exit}' "$ANVIL_LOG")"
BOT_KEY="$(awk '/^Private Keys/{flag=1; next} flag && /^\(1\)/{print $2; exit}' "$ANVIL_LOG")"
if [[ -z "$BORROWER_KEY" || -z "$BOT_KEY" ]]; then
  echo "ERROR: could not parse anvil's default private keys from its startup log." >&2
  cat "$ANVIL_LOG" >&2
  exit 1
fi

echo "== 2. Deploying the real QIE Forge demo stack (factory/router/oracle/vault) =="
(
  cd "$CONTRACTS_DIR"
  DEPLOYER_PRIVATE_KEY="$BORROWER_KEY" forge script script/DeployDemo.s.sol:DeployDemo \
    --rpc-url "$RPC_URL" --broadcast --private-key "$BORROWER_KEY" -vv
) | tee "$DEPLOY_LOG"

extract_addr() {
  grep -E "^\s*$1:" "$DEPLOY_LOG" | awk '{print $NF}' | tail -1
}

FACTORY_ADDR="$(extract_addr 'Factory')"
ROUTER_ADDR="$(extract_addr 'Router')"
ORACLE_ADDR="$(extract_addr 'Oracle')"
WQIE_ADDR="$(extract_addr 'WQIE')"
TUSD_ADDR="$(extract_addr 'TUSD')"
VAULT_ADDR="$(extract_addr 'Vault')"

for name_value in "Factory:$FACTORY_ADDR" "Router:$ROUTER_ADDR" "Oracle:$ORACLE_ADDR" "WQIE:$WQIE_ADDR" "TUSD:$TUSD_ADDR" "Vault:$VAULT_ADDR"; do
  value="${name_value#*:}"
  if [[ -z "$value" || ! "$value" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: failed to parse a deployed address (${name_value}) from forge script output." >&2
    exit 1
  fi
done

echo
echo "== 3. Running the liquidation bot against the real deployment =="
QIE_FORGE_RPC_URL="$RPC_URL" \
QIE_FORGE_DEMO_BORROWER_KEY="$BORROWER_KEY" \
QIE_FORGE_DEMO_BOT_KEY="$BOT_KEY" \
QIE_FORGE_VAULT_ADDRESS="$VAULT_ADDR" \
QIE_FORGE_ORACLE_ADDRESS="$ORACLE_ADDR" \
QIE_FORGE_WQIE_ADDRESS="$WQIE_ADDR" \
QIE_FORGE_TUSD_ADDRESS="$TUSD_ADDR" \
node "$REPO_ROOT/scripts/liquidation-bot-demo.mjs"
