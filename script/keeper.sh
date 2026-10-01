#!/usr/bin/env bash
# Torque keeper: knocks out every position whose barrier a fresh Chainlink NVDA price has crossed.
# Knock-outs are permissionless; this is just the operator running one.
#
#   RH_RPC_URL=<quicknode url> MARKET=<TorqueMarket> ACCOUNT=<cast keystore name> ./script/keeper.sh
#   INTERVAL=30 (seconds, default)    DRY_RUN=1 (log only, send nothing)
set -euo pipefail
: "${RH_RPC_URL:?set RH_RPC_URL}" "${MARKET:?set MARKET}"
INTERVAL="${INTERVAL:-30}"

while true; do
  read -r price fresh < <(cast call "$MARKET" 'oraclePrice()(uint256,bool)' --rpc-url "$RH_RPC_URL" | awk '{print $1}' | tr '\n' ' ')
  if [[ "$fresh" != "true" ]]; then
    echo "$(date -u +%FT%TZ) feed stale; knock-outs paused by contract"
  else
    ids=$(cast call "$MARKET" 'openPositionIds()(uint256[])' --rpc-url "$RH_RPC_URL" | tr -d '[] ' | tr ',' ' ')
    for id in $ids; do
      barrier=$(cast call "$MARKET" 'barrierOf(uint256)(uint256)' "$id" --rpc-url "$RH_RPC_URL" | awk '{print $1}')
      if (( price <= barrier )); then
        echo "$(date -u +%FT%TZ) position $id: price $price <= barrier $barrier -> knockOut"
        if [[ -z "${DRY_RUN:-}" ]]; then
          cast send "$MARKET" 'knockOut(uint256)' "$id" --rpc-url "$RH_RPC_URL" --account "${ACCOUNT:?set ACCOUNT}" || true
        fi
      fi
    done
  fi
  sleep "$INTERVAL"
done
