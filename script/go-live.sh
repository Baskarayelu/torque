#!/usr/bin/env bash
# One command from "funds landed" to "live, verified, published". Preflight first; nothing is broadcast unless every
# check passes and you type "deploy" (or YES=1).
#
#   RH_RPC_URL=<QuickNode URL> KEYSTORE=<path to keystore file> ./script/go-live.sh
#
# Optional: SEED_USDG (6dp, default 15000000), DEMO_USDG (default 7000000: 5 to fill the vault on camera + 2 of margin),
#           FILM=1 (record the mainnet Demo Video right after; NARRATION_MP3=<ElevenLabs mainnet demo mp3> for the voice),
#           MIN_WINDOW_MIN (default 60: refuse if Chainlink's 12-hour window closes sooner), YES=1 (no prompt).
# Rehearsal: FORK_REHEARSAL=1 RH_RPC_URL=http://127.0.0.1:8545 runs the same sequence on a local fork with a test
#           keystore and skips Sourcify, git and Vercel (it prints what it would have run), to time the whole thing.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD; LANDING="${LANDING_DIR:-$(dirname "$ROOT")/torque-landing}"
: "${RH_RPC_URL:?set RH_RPC_URL}" "${KEYSTORE:?set KEYSTORE (foundry keystore file)}"
SEED_USDG=${SEED_USDG:-15000000}; DEMO_USDG=${DEMO_USDG:-7000000}; MIN_WINDOW_MIN=${MIN_WINDOW_MIN:-60}
REHEARSAL=${FORK_REHEARSAL:-}
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; FEED=0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15; POOL=0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3
RUN="$ROOT/broadcast/go-live-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$RUN"; LOG="$RUN/go-live.log"
exec > >(tee -a "$LOG") 2>&1
T0=$(date +%s); phase() { echo; echo "== $1  (+$(( $(date +%s) - T0 ))s)"; }
ok() { echo "  ✓ $*"; }; die() { echo "  ✗ $*"; echo "STOPPED. Nothing after this point ran. Log: $LOG"; exit 1; }
if [ -n "$REHEARSAL" ]; then
  case "$RH_RPC_URL" in http://127.0.0.1*|http://localhost*) ;; *) die "FORK_REHEARSAL needs a local fork RPC";; esac
  echo "FORK REHEARSAL: local fork only. No Sourcify, git or Vercel."
fi

PASS="$RUN/.pw"; trap 'rm -f "$PASS"' EXIT; umask 077
if [ -n "${KEYSTORE_PASSWORD_FILE:-}" ]; then cp "$KEYSTORE_PASSWORD_FILE" "$PASS"; else read -r -s -p "Keystore password: " pw; echo; printf '%s' "$pw" > "$PASS"; unset pw; fi

phase "1/7 Preflight"
for t in forge cast python3 node npx curl git; do command -v $t >/dev/null || die "missing tool: $t"; done; ok "tools"
[ "$(cast chain-id --rpc-url "$RH_RPC_URL")" = 4663 ] || die "RPC is not Robinhood Chain mainnet (4663)"; ok "RPC is chain 4663"
DEPLOYER=$(cast wallet address --keystore "$KEYSTORE" --password-file "$PASS") || die "keystore did not decrypt"; ok "deployer $DEPLOYER"
if [ -z "$REHEARSAL" ]; then
  for r in "$ROOT" "$LANDING"; do
    [ -z "$(git -C "$r" status --porcelain)" ] || die "$(basename "$r") has uncommitted changes"
    git -C "$r" fetch -q origin && [ "$(git -C "$r" rev-parse HEAD)" = "$(git -C "$r" rev-parse origin/main)" ] || die "$(basename "$r") is not at origin/main"
  done; ok "both repos clean and at origin/main"
  [ "$(python3 -c "import json;print(json.load(open('deployment.json'))['status'])")" = fork-only ] || die "deployment.json is not fork-only: already deployed?"
  curl -sf https://sourcify.dev/server/health >/dev/null || die "Sourcify unreachable"; ok "Sourcify reachable"
  npx --yes vercel@latest whoami >/dev/null 2>&1 || die "Vercel CLI not logged in"
  [ -f "$ROOT/app/.vercel/project.json" ] && [ -f "$LANDING/.vercel/project.json" ] || die "a Vercel project is not linked"; ok "Vercel logged in, both projects linked"
fi
NEED=$((SEED_USDG + DEMO_USDG)); BAL=$(cast call $USDG 'balanceOf(address)(uint256)' "$DEPLOYER" --rpc-url "$RH_RPC_URL" | awk '{print $1}')
[ "$BAL" -ge "$NEED" ] || die "USDG $(python3 -c "print($BAL/1e6)") < needed $(python3 -c "print($NEED/1e6)") (seed + demo)"; ok "USDG $(python3 -c "print($BAL/1e6)") ≥ $(python3 -c "print($NEED/1e6)")"
# Chainlink: fresh, and how long the 12-hour window stays open (the feed freezes Fri 20:00 → Mon 00:00 UTC)
read -r UPDATED PRICE <<<"$(cast call $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RH_RPC_URL" | awk 'NR==2{p=$1} NR==4{u=$1} END{print u, p}')"
NOW=$(cast block latest -f timestamp --rpc-url "$RH_RPC_URL"); LEFT=$(( (UPDATED + 43200 - NOW) / 60 ))
echo "  Chainlink NVDA \$$(python3 -c "print(round($PRICE/1e8,2))"), printed $(( (NOW - UPDATED) / 60 )) min ago; opens and seeding allowed for $LEFT more min (until $(date -u -r $((UPDATED + 43200)) '+%a %H:%M UTC'))"
[ "$LEFT" -ge "$MIN_WINDOW_MIN" ] || die "fewer than $MIN_WINDOW_MIN min left in the 12-hour window"; ok "price fresh"
# Pool 30-minute average must agree within 1.5% (USDG is token0: USDG per NVDA = 1e12 / 1.0001^tick)
TW=$(python3 - "$RH_RPC_URL" $POOL $PRICE <<'PY'
import subprocess, sys
rpc, pool, price = sys.argv[1], sys.argv[2], int(sys.argv[3]) / 1e8
out = subprocess.run(["cast", "call", pool, "observe(uint32[])(int56[],uint160[])", "[1800,0]", "--rpc-url", rpc], capture_output=True, text=True, check=True).stdout
import re
a, b = [int(x) for x in re.findall(r"(-?\d+)(?: \[[^\]]*\])?(?=,|\]$)", out.split("\n")[0].strip())]
twap = 1e12 / 1.0001 ** ((b - a) / 1800)
print(f"{twap:.2f} {abs(twap / price - 1) * 100:.2f}")
PY
)
read -r TWAP DEV <<<"$TW"; echo "  pool 30-min average \$$TWAP, $DEV% from Chainlink"
python3 -c "import sys; sys.exit(0 if $DEV < 1.5 else 1)" || die "pool disagrees with Chainlink by $DEV% (band 1.5%)"; ok "market agrees"
phase "2/7 Tests"
forge build -q || die "build failed"
forge test --no-match-path "test/fork/*" -q > "$RUN/tests.log" 2>&1 || die "test suite failed (see $RUN/tests.log)"; ok "unit, adversarial and invariant suites pass"
# a rehearsal's anvil is itself a fork; fork tests go to real mainnet instead of forking the fork
FORK_TEST_RPC=$RH_RPC_URL; [ -n "$REHEARSAL" ] && FORK_TEST_RPC=https://rpc.mainnet.chain.robinhood.com
RH_RPC_URL="$FORK_TEST_RPC" forge test --match-path "test/fork/*" -q > "$RUN/fork-tests.log" 2>&1 || die "fork tests against mainnet state failed"; ok "fork tests pass against live mainnet state"
phase "3/7 Simulate the deployment (no broadcast)"
SIM=$(SEED_USDG=$SEED_USDG forge script script/Deploy.s.sol --rpc-url "$RH_RPC_URL" --keystore "$KEYSTORE" --password-file "$PASS" --sender "$DEPLOYER" 2>&1) || { echo "$SIM" | tail -20; die "simulation failed"; }
GAS_ETH=$(echo "$SIM" | grep -oE "Estimated amount required: [0-9.]+" | awk '{print $4}')
ETH=$(cast balance "$DEPLOYER" --rpc-url "$RH_RPC_URL" --ether)
python3 -c "import sys; sys.exit(0 if $ETH >= 2 * ${GAS_ETH:-0} else 1)" || die "ETH $ETH < 2× estimated gas ${GAS_ETH:-?}"; ok "simulation passes; gas ~${GAS_ETH:-?} ETH, balance $ETH ETH"
if [ -z "${YES:-}" ]; then read -r -p "Deploy to Robinhood Chain mainnet now? Type deploy: " a; [ "$a" = deploy ] || die "not confirmed"; fi

phase "4/7 Deploy and seed"
VERIFY=(--verify --verifier sourcify); [ -n "$REHEARSAL" ] && VERIFY=()
SEED_USDG=$SEED_USDG forge script script/Deploy.s.sol --rpc-url "$RH_RPC_URL" --keystore "$KEYSTORE" --password-file "$PASS" --sender "$DEPLOYER" \
  --broadcast --slow ${VERIFY[@]+"${VERIFY[@]}"} --chain 4663 > "$RUN/deploy.log" 2>&1 || { tail -30 "$RUN/deploy.log"; die "deploy failed (see $RUN/deploy.log)"; }
MARKET=$(grep -oE "TorqueMarket 0x[0-9a-fA-F]{40}" "$RUN/deploy.log" | head -1 | awk '{print $2}')
VAULT=$(grep -oE "TorqueVault +0x[0-9a-fA-F]{40}" "$RUN/deploy.log" | head -1 | awk '{print $NF}')
BJ=broadcast/Deploy.s.sol/4663/run-latest.json; cp "$BJ" "$RUN/"
read -r SEEDTX BLOCK <<<"$(python3 - "$BJ" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); txs, rec = d["transactions"], d["receipts"]
seed = next(t["hash"] for t in txs if (t.get("function") or "").startswith("deposit"))
print(seed, min(int(r["blockNumber"], 16) for r in rec))
PY
)"
[ "$(cast call "$VAULT" 'market()(address)' --rpc-url "$RH_RPC_URL")" = "$MARKET" ] || die "vault is not wired to the market"
[ "$(cast call "$VAULT" 'totalAssets()(uint256)' --rpc-url "$RH_RPC_URL" | awk '{print $1}')" = "$SEED_USDG" ] || die "vault was not seeded"
ok "TorqueMarket $MARKET"; ok "TorqueVault  $VAULT, seeded with $(python3 -c "print($SEED_USDG/1e6)") USDG (tx $SEEDTX), block $BLOCK"

phase "5/7 Source verification"
if [ -n "$REHEARSAL" ]; then echo "  (rehearsal) would check Sourcify for $MARKET and $VAULT"; else
  for i in 1 2 3 4 5 6; do
    S=$(curl -s "https://sourcify.dev/server/check-by-addresses?addresses=$MARKET,$VAULT&chainIds=4663")
    echo "$S" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if all(x.get('status') in ('perfect','partial') for x in d) else 1)" && break
    [ $i = 3 ] && { forge verify-contract "$MARKET" src/TorqueMarket.sol:TorqueMarket --verifier sourcify --chain 4663 || true; forge verify-contract "$VAULT" src/TorqueVault.sol:TorqueVault --verifier sourcify --chain 4663 || true; }
    sleep 20
  done
  echo "$S" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if all(x.get('status') in ('perfect','partial') for x in d) else 1)" || die "Sourcify has not verified both contracts (deployment is live; rerun verification by hand)"
  ok "both contracts verified on Sourcify"
fi

phase "6/7 Flip deployment.json to mainnet and publish"
DEPLOYED_AT=$(date -u -r "$(cast block "$BLOCK" -f timestamp --rpc-url "$RH_RPC_URL")" '+%Y-%m-%d %H:%M UTC')
STATE="$ROOT/deployment.json"; [ -n "$REHEARSAL" ] && { STATE="$RUN/deployment.json"; cp deployment.json "$STATE"; }
python3 - "$STATE" "$MARKET" "$VAULT" "$BLOCK" "$DEPLOYED_AT" "$SEEDTX" <<'PY'
import json, sys
p, market, vault, block, at, seed = sys.argv[1:]
d = json.load(open(p)); d["status"] = "mainnet"
d["mainnet"] = {"MARKET": market, "VAULT": vault, "deployBlock": int(block), "deployedAt": at, "seedTx": seed}
json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
PY
if [ -n "$REHEARSAL" ]; then
  echo "  (rehearsal) wrote $STATE; would run: apply-deployment.py, commit + push both repos, vercel deploy --prod for dashboard and landing"
else
  RH_RPC_URL="$RH_RPC_URL" python3 script/apply-deployment.py || die "apply-deployment refused (contracts are live; fix and rerun the apply step)"
  git add -A deployment.json README.md submission video app/public/config.json && git commit -q -m "Deploy TORQUE to Robinhood Chain mainnet" && git push -q origin main
  git -C "$LANDING" add config.json && git -C "$LANDING" commit -q -m "Point the landing page at the mainnet deployment" && git -C "$LANDING" push -q origin main
  ok "committed and pushed both repos"
  (cd "$ROOT/app" && npx --yes vercel@latest deploy --prod --yes > "$RUN/vercel-dashboard.log" 2>&1) || die "dashboard deploy failed"
  # Vercel Hobby blocks deploys that carry a private repo's commit author; deploy the landing from a git-less export of main
  EXP="$RUN/landing-export"; mkdir -p "$EXP/.vercel" && git -C "$LANDING" archive HEAD | tar -x -C "$EXP" && cp "$LANDING/.vercel/project.json" "$EXP/.vercel/" && rm -rf "$EXP/social" "$EXP/docs"
  (cd "$EXP" && npx --yes vercel@latest deploy --prod --yes > "$RUN/vercel-landing.log" 2>&1) || die "landing deploy failed"
  LAND=$(python3 -c "import json;print(json.load(open('deployment.json'))['landing'])")
  curl -s "$LAND/" | grep -q "Live on Robinhood Chain mainnet" || die "landing is not showing the mainnet status"
  DASH=$(python3 -c "import json;print(json.load(open('deployment.json'))['dashboard'])")
  curl -s "$DASH/config.json" | grep -qi "$MARKET" || die "dashboard is not serving the new config"; ok "dashboard and landing redeployed"
fi

phase "7/7 Film"
if [ -n "${FILM:-}" ] && [ -z "$REHEARSAL" ]; then
  PK=$(cast wallet decrypt-keystore --keystore-dir "$(dirname "$KEYSTORE")" "$(basename "$KEYSTORE")" --unsafe-password "$(cat "$PASS")" 2>/dev/null | grep -oE "0x[0-9a-fA-F]{64}")
  RPC="$RH_RPC_URL" PK="$PK" ./video/build-demo.sh "$RUN/demo" || die "demo recording failed (deployment is live)"
  unset PK; ok "Demo Video: $RUN/demo/torque-demo.mp4"
else
  echo "  skipped (FILM=1 to record the mainnet demo here)"
fi

phase "Done"
echo "HackQuest contract field:"
echo "Robinhood Chain: $MARKET — TorqueMarket"
echo "Robinhood Chain: $VAULT — TorqueVault (USDG LP)"
echo "Total $(( $(date +%s) - T0 ))s. Log: $LOG"
