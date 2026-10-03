#!/usr/bin/env bash
# Checks every public claim about TORQUE on Robinhood Chain mainnet against the chain itself, and prints PASS or FAIL
# for each. Needs Foundry's `cast`, `curl` and `python3`. Each check is also on torque.0xo.in/docs/verify as a single
# command you can paste on its own.
#
#   ./script/verify-claims.sh            RH_RPC_URL overrides the public RPC
set -uo pipefail
RPC="${RH_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
MARKET=0xbee6Da89F879B018Fea5d7A78311db720B9D8096
VAULT=0xb4dBEF56F9E93ED9A7649E065252dc98013B96Bf
NVDA=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
DEPLOYER=0xA22B72d975d608Bd9Dd4945F4B28a4479A97967F
FROM_BLOCK=78466999
fails=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; else echo "FAIL  $1  (expected $3, got $2)"; fails=$((fails + 1)); fi; }

echo "TORQUE claims, read at block $(cast block-number --rpc-url "$RPC") ($(date -u +%FT%TZ))"

# 1. Both contracts are verified: an exact match of creation and runtime bytecode on Sourcify
for a in $MARKET $VAULT; do
  check "verified on Sourcify (exact match): $a" "$(curl -s "https://sourcify.dev/server/v2/contract/4663/$a" | python3 -c "import json,sys;print(json.load(sys.stdin).get('match'))")" "exact_match"
done

# 2. No owner, no proxy, no admin functions
for a in $MARKET $VAULT; do
  check "no owner(): $a" "$(cast call "$a" 'owner()(address)' --rpc-url "$RPC" >/dev/null 2>&1 && echo has-owner || echo reverts)" "reverts"
  check "not an upgradeable proxy (EIP-1967 slot empty): $a" "$(cast storage "$a" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$RPC")" "0x0000000000000000000000000000000000000000000000000000000000000000"
done
abi_writes() { curl -s "https://sourcify.dev/server/v2/contract/4663/$1?fields=abi" | python3 -c "import json,sys;print(','.join(sorted(f['name'] for f in json.load(sys.stdin)['abi'] if f['type']=='function' and f['stateMutability'] not in ('view','pure'))))"; }
check "market can only be traded, closed, knocked out, claimed, or unwound after a dead feed" "$(abi_writes $MARKET)" "claim,close,knockOut,open,reportFeedDown,uniswapV3SwapCallback,unwind"
check "vault has only ERC-4626 / ERC-20 functions, lend (market only) and a one-shot setMarket" "$(abi_writes $VAULT)" "approve,deposit,lend,mint,redeem,setMarket,transfer,transferFrom,withdraw"
check "setMarket is spent: the deployer cannot call it again" "$(cast call $VAULT 'setMarket(address)' $MARKET --from $DEPLOYER --rpc-url "$RPC" 2>&1 | grep -o 0x06ddda6b)" "0x06ddda6b"

# 3. The vault is at its $20 cap
check "vault cap is 20 USDG" "$(cast call $VAULT 'VAULT_CAP()(uint256)' --rpc-url "$RPC" | awk '{print $1}')" "20000000"
check "vault takes no more deposits (maxDeposit is 0)" "$(cast call $VAULT 'maxDeposit(address)(uint256)' 0x0000000000000000000000000000000000000001 --rpc-url "$RPC" | awk '{print $1}')" "0"

# 4. Hedge 1:1: NVDA held by the market covers the NVDA owed to open positions
held=$(cast call $NVDA 'balanceOf(address)(uint256)' $MARKET --rpc-url "$RPC" | awk '{print $1}')
owed=0
for id in $(cast call $MARKET 'openPositionIds()(uint256[])' --rpc-url "$RPC" | tr -d '[],'); do
  q=$(cast call $MARKET 'getPosition(uint256)((address,uint128,uint128,uint128,uint128,uint64))' "$id" --rpc-url "$RPC" | tr -d '()' | awk -F', ' '{print $2}' | awk '{print $1}')
  owed=$(python3 -c "print($owed + $q)")
done
check "hedged 1:1 (NVDA held $held >= owed $owed)" "$(python3 -c "print($held >= $owed)")" "True"

# 5. No bad debt
check "bad debt to date is 0" "$(cast call $MARKET 'totalBadDebt()(uint256)' --rpc-url "$RPC" | awk '{print $1}')" "0"

# 6. Every position: opened and closed on chain, each close repaid the vault at least its loan
echo "positions (from TorqueMarket's own events since block $FROM_BLOCK):"
python3 - "$RPC" "$MARKET" "$FROM_BLOCK" <<'PY'
import json, subprocess, sys
rpc, market, frm = sys.argv[1:4]
def logs(sig):
    out = subprocess.run(["cast", "logs", "--from-block", frm, "--address", market, sig, "--rpc-url", rpc, "--json"], capture_output=True, text=True, check=True).stdout
    return json.loads(out)
opened = {int(l["topics"][1], 16): (l["transactionHash"], int(l["data"][2 + 64 * 3: 2 + 64 * 4], 16)) for l in logs("Opened(uint256 indexed,address indexed,uint256,uint256,uint256,uint256)")}
closed = {}
for l in logs("Closed(uint256 indexed,uint256,uint256,uint256)"):
    d = l["data"][2:]
    closed[int(l["topics"][1], 16)] = (l["transactionHash"], int(d[64:128], 16), int(d[128:192], 16))
bad = 0
for i in sorted(opened):
    otx, principal = opened[i]
    if i in closed:
        ctx, repaid, payout = closed[i]
        ok = repaid >= principal
        bad += not ok
        print(f"  #{i} open {otx}\n     close {ctx}  vault repaid {repaid/1e6:.6f} for a {principal/1e6:.6f} loan {'PASS' if ok else 'FAIL'}; trader paid {payout/1e6:.6f}")
    else:
        print(f"  #{i} open {otx}  (still open)")
sys.exit(1 if bad else 0)
PY
[[ $? == 0 ]] && echo "PASS  every close repaid the vault in full" || { echo "FAIL  a close did not repay the vault in full"; fails=$((fails + 1)); }

echo
(( fails == 0 )) && echo "All claims hold." || echo "$fails claim(s) failed."
exit $(( fails > 0 ))
