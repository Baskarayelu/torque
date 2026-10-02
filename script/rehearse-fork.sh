#!/usr/bin/env bash
# Local mainnet-fork rehearsal: forks Robinhood Chain mainnet, deploys TORQUE, seeds the vault and opens
# positions from anvil's public test wallets. Nothing here touches mainnet; the fork runs on 127.0.0.1.
#
#   ./script/rehearse-fork.sh up        start the fork, deploy, seed, open two positions, write app/public/config.fork.json
#   ./script/rehearse-fork.sh feed <p>  replace the fork's Chainlink feed with a test feed printing price <p> (USD, e.g. 190.5)
#   ./script/rehearse-fork.sh down      stop the fork
set -euo pipefail
cd "$(dirname "$0")/.."
A=http://127.0.0.1:8545
UPSTREAM="${RH_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
FEED=0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15
WHALE=0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010   # Morpho Blue holds USDG; impersonated on the fork only
# anvil's well-known public test keys (mnemonic "test test ... junk"); worthless outside a local fork
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; W0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; W1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
W2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

case "${1:-}" in
up)
  pkill -f "anvil --fork-url" || true
  (anvil --fork-url "$UPSTREAM" --port 8545 --chain-id 4663 --block-time 1 > /tmp/torque-anvil.log 2>&1 &)
  for _ in $(seq 1 40); do cast chain-id --rpc-url $A >/dev/null 2>&1 && break; sleep 1; done
  cast rpc anvil_impersonateAccount $WHALE --rpc-url $A >/dev/null
  cast rpc anvil_setBalance $WHALE 0x56BC75E2D63100000 --rpc-url $A >/dev/null
  for w in $W0 $W1 $W2; do cast send $USDG 'transfer(address,uint256)' $w 40000000 --from $WHALE --unlocked --rpc-url $A >/dev/null; done
  out=$(SEED_USDG=15000000 forge script script/Deploy.s.sol --rpc-url $A --private-key $K0 --broadcast --slow 2>&1)
  rm -rf broadcast
  MARKET=$(echo "$out" | grep -oE "TorqueMarket 0x[0-9a-fA-F]{40}" | head -1 | awk '{print $2}')
  VAULT=$(echo "$out" | grep -oE "TorqueVault +0x[0-9a-fA-F]{40}" | head -1 | awk '{print $NF}')
  # wallet 0: $2 at 5x; wallet 1: $1 at 2x
  cast send $USDG 'approve(address,uint256)' $MARKET 10000000 --private-key $K0 --rpc-url $A >/dev/null
  cast send $MARKET 'open(uint256,uint256,uint256)' 2000000 50000 0 --private-key $K0 --rpc-url $A >/dev/null
  cast send $USDG 'approve(address,uint256)' $MARKET 10000000 --private-key $K1 --rpc-url $A >/dev/null
  cast send $MARKET 'open(uint256,uint256,uint256)' 1000000 20000 0 --private-key $K1 --rpc-url $A >/dev/null
  python3 - "$MARKET" "$VAULT" <<'PY'
import json, sys
c = json.load(open("app/public/config.json"))
c.update({"environment": "fork-rehearsal", "rpc": "http://127.0.0.1:8545", "MARKET": sys.argv[1], "VAULT": sys.argv[2]})
json.dump(c, open("app/public/config.fork.json", "w"), indent=2)
PY
  echo "market=$MARKET vault=$VAULT"
  ;;
feed)
  # Swap the fork's feed for TORQUE's own test feed (test/mocks MockFeed) and print a price. Fork only.
  code=$(forge inspect MockFeed deployedBytecode)
  cast rpc anvil_setCode $FEED "$code" --rpc-url $A >/dev/null
  for slot in 0 1 2 3; do cast rpc anvil_setStorageAt $FEED $(printf '0x%064x' $slot) 0x$(printf '%064d' 0) --rpc-url $A >/dev/null; done
  ans=$(python3 -c "print(round(float('$2') * 1e8))")
  cast send $FEED 'push(int256)' "$ans" --private-key $K0 --rpc-url $A >/dev/null
  echo "fork feed now prints $2"
  ;;
down)
  pkill -f "anvil --fork-url" || true
  ;;
*)
  echo "usage: $0 up | feed <price> | down"; exit 1;;
esac
