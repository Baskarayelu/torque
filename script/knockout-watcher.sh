#!/usr/bin/env bash
# TORQUE knock-out watcher. Knock-outs are permissionless: anyone may close a position once a fresh Chainlink
# print is at or below its knock-out level, and the vault is repaid first. This script finds those positions and,
# if you ask it to, sends the knock-outs. It needs only Foundry's `cast`.
#
#   ./script/knockout-watcher.sh                   watch: print the price, both checks and every position, every 30 s
#   ./script/knockout-watcher.sh --once            one pass, then exit
#   ACCOUNT=<cast keystore> ./script/knockout-watcher.sh --send     also send each knock-out (simulated first)
#   PRIVATE_KEY=0x... ./script/knockout-watcher.sh --send           same, with a raw key from the environment
#
#   RH_RPC_URL  RPC endpoint (default: the public Robinhood Chain RPC)
#   MARKET      TorqueMarket address (default: the mainnet deployment in deployment.json)
#   INTERVAL    seconds between passes (default 30)
#
# Eligibility is exactly TorqueMarket.knockOut(): the feed is fresh (printed in the last 12 h), the pool's 30-minute
# average agrees within 1.5% or the print is under 30 minutes old, and the price is at or below barrierOf(id).
# Before each send the call is simulated from your address, so a position someone else closed first is skipped.
set -uo pipefail
cd "$(dirname "$0")/.."

RPC="${RH_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
MARKET="${MARKET:-$(python3 -c "import json;print(json.load(open('deployment.json'))['mainnet']['MARKET'])" 2>/dev/null)}"
INTERVAL="${INTERVAL:-30}"
SEND=0; ONCE=0
for a in "$@"; do
  case "$a" in
    --send) SEND=1 ;;
    --once) ONCE=1 ;;
    -h|--help) sed -n 2,19p "$0"; exit 0 ;;
    *) echo "unknown option $a (try --help)"; exit 2 ;;
  esac
done
[[ -n "$MARKET" ]] || { echo "set MARKET (no deployment.json found)"; exit 2; }
command -v cast >/dev/null || { echo "needs Foundry's cast: https://getfoundry.sh"; exit 2; }

SIGNER=()
FROM=""
if (( SEND )); then
  if [[ -n "${ACCOUNT:-}" ]]; then
    SIGNER=(--account "$ACCOUNT")
    FROM=$(cast wallet address --account "$ACCOUNT") || { echo "could not open keystore $ACCOUNT"; exit 2; }
  elif [[ -n "${PRIVATE_KEY:-}" ]]; then
    SIGNER=(--private-key "$PRIVATE_KEY")
    FROM=$(cast wallet address --private-key "$PRIVATE_KEY") || { echo "PRIVATE_KEY is not a valid key"; exit 2; }
  else
    echo "--send needs ACCOUNT (a cast keystore name) or PRIVATE_KEY in the environment"; exit 2
  fi
fi

now() { date -u +%FT%TZ; }
call() { cast call "$MARKET" "$@" --rpc-url "$RPC" 2>/dev/null; }
usd() { python3 -c "print(f'\${int(\"$1\")/1e6:,.2f}')"; }

echo "TORQUE knock-out watcher · market $MARKET · $( ((SEND)) && echo "sending as $FROM" || echo "watch only, nothing is sent")"

while true; do
  # priceStatus() -> (feed price, feed age s, pool 30-min average, deviation bps, feed fresh, pool agrees)
  if ! status=$(call 'priceStatus()(uint256,uint256,uint256,uint256,bool,bool)' | awk '{print $1}' | tr '\n' ' '); [[ -z "$status" ]]; then
    echo "$(now) RPC read failed; retrying next pass"
  else
    read -r price age twap dev fresh agrees <<<"$status"
    trusted=$([[ "$fresh" == true && ( "$agrees" == true || "$age" -le 1800 ) ]] && echo true || echo false)
    echo "$(now) NVDA $(usd "$price") · printed $(python3 -c "a=$age;print(f'{a/3600:.1f} h' if a>=5400 else f'{a//60} min')") ago · fresh $fresh · pool $(usd "$twap") ($((dev)) bps) agrees $agrees · knock-outs allowed $trusted"
    ids=$(call 'openPositionIds()(uint256[])' | tr -d '[] ' | tr ',' ' ')
    [[ -z "$ids" ]] && echo "  no open positions"
    for id in $ids; do
      barrier=$(call 'barrierOf(uint256)(uint256)' "$id" | awk '{print $1}')
      [[ -z "$barrier" ]] && { echo "  #$id closed while reading"; continue; }
      dist=$(python3 -c "print(f'{($price/$barrier-1)*100:+.2f}%')")
      if (( price > barrier )); then
        echo "  #$id knock-out $(usd "$barrier") · price is $dist above it · waiting"
      elif [[ "$trusted" != true ]]; then
        echo "  #$id knock-out $(usd "$barrier") · price is at or below it, but the contract will refuse: $([[ "$fresh" != true ]] && echo "the feed is stale" || echo "the pool disagrees and the print is over 30 min old") · waiting"
      else
        echo "  #$id knock-out $(usd "$barrier") · ELIGIBLE (price $dist from the level)"
        if (( SEND )); then
          if out=$(cast call "$MARKET" 'knockOut(uint256)(uint256)' "$id" --from "$FROM" --rpc-url "$RPC" 2>&1); then
            if tx=$(cast send "$MARKET" 'knockOut(uint256)' "$id" "${SIGNER[@]}" --rpc-url "$RPC" --json 2>&1 | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['transactionHash'], d['status'])" 2>/dev/null); then
              echo "    sent knockOut($id): tx ${tx%% *} status ${tx##* } (trader residual $(usd "$(awk '{print $1}' <<<"$out")") credited to claim)"
            else
              echo "    send failed; will retry next pass"
            fi
          else
            echo "    simulation refused ($(grep -oE 'NotKnockable|StaleFeed|PoolPriceMismatch|UnknownPosition|execution reverted[^,]*' <<<"$out" | head -1)); skipped"
          fi
        fi
      fi
    done
  fi
  (( ONCE )) && break
  sleep "$INTERVAL"
done
