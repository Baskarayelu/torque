#!/usr/bin/env bash
# Builds the Demo Video for the state in ../deployment.json: narration, a recorded run with real transactions, mux.
#   ./build-demo.sh out_dir                          (voice: NARRATION_MP3=<ElevenLabs mp3>, else macOS say as a guide track)
# fork-only: needs `./script/rehearse-fork.sh up` running; records the fork dashboard build with anvil test wallet 2.
# mainnet:   RPC=<rpc> PK=<demo wallet key> ./build-demo.sh out_dir   (records app.torque.0xo.in)
set -euo pipefail
OUT="$(mkdir -p "${1:-out}" && cd "${1:-out}" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
VOICE="${VOICE:-Samantha}"
STATUS=$(python3 -c "import json;print(json.load(open('$ROOT/deployment.json'))['status'])")
LANDING_URL=${LANDING_URL:-$(python3 -c "import json;print(json.load(open('$ROOT/deployment.json'))['landing'])")}
if [ "$STATUS" = "fork-only" ]; then
  A=http://127.0.0.1:8545
  cast chain-id --rpc-url $A >/dev/null || { echo "start the fork first: ./script/rehearse-fork.sh up"; exit 1; }
  CFG="$ROOT/app/public/config.fork.json"
  MARKET=$(python3 -c "import json;print(json.load(open('$CFG'))['MARKET'])")
  # make room in the $20 vault for the demo's $2 at 5x: close position #1 (wallet 0) if it is still open
  if cast call $MARKET 'openPositionIds()(uint256[])' --rpc-url $A | grep -q '\[1,'; then
    cast send $MARKET 'close(uint256,uint256)' 1 0 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --rpc-url $A >/dev/null
  fi
  (cd "$ROOT/app" && npx vite build --outDir "$OUT/dash" --emptyOutDir >/dev/null) && cp "$CFG" "$OUT/dash/config.json"
  PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('',0));print(s.getsockname()[1])")
  python3 -m http.server "$PORT" --directory "$OUT/dash" >/dev/null 2>&1 & SERVER=$!; trap 'kill $SERVER 2>/dev/null || true' EXIT; sleep 1
  DASH_URL=http://localhost:$PORT/; RPC=$A
  PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # anvil public test wallet 2; fork only
  export FORK_SCRIPT="$ROOT/script/rehearse-fork.sh"
else
  DASH_URL=${DASH_URL:-$(python3 -c "import json;print(json.load(open('$ROOT/deployment.json'))['dashboard'])")/}
  : "${RPC:?set RPC}" "${PK:?set PK (demo wallet)}"
fi
if [ -n "${NARRATION_MP3:-}" ]; then
  python3 "$HERE/split_narration.py" "$HERE/demo-narration.json" "$NARRATION_MP3" "$OUT" n
else
  python3 - "$HERE/demo-narration.json" "$OUT" "$VOICE" <<'PY'
import json, re, subprocess, sys
steps=json.load(open(sys.argv[1])); out=sys.argv[2]; voice=sys.argv[3]; d={}
for s in steps:
    wav=f"{out}/n_{s['id']}.wav"; aiff=f"{out}/n_{s['id']}.aiff"
    subprocess.run(["say","-v",voice,"-r","182","-o",aiff,re.sub(r"\[[^\]]*\]","",s["text"])],check=True)
    subprocess.run(["ffmpeg","-y","-i",aiff,wav],check=True,capture_output=True)
    d[s["id"]]=float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",wav]).decode())
json.dump(d,open(f"{out}/durations.json","w"),indent=1)
PY
fi
rm -rf "$OUT/frames"
LANDING_URL="$LANDING_URL" DASH_URL="$DASH_URL" RPC="$RPC" PK="$PK" OUT="$OUT" node "$HERE/demo.js" | tee "$OUT/run.log"
python3 - "$OUT" <<'PY'
import json, subprocess, sys
out = sys.argv[1]
marks=json.load(open(f"{out}/marks.json"))
inputs=["-i",f"{out}/screen.mp4"]; filters=[]; labels=""
for i,m in enumerate(marks):
    inputs+=["-i",f"{out}/n_{m['id']}.wav"]
    ms=int(m["start"]*1000)
    filters.append(f"[{i+1}:a]adelay={ms}|{ms}[a{i}]"); labels+=f"[a{i}]"
filters.append(f"{labels}amix=inputs={len(marks)}:normalize=0[aout]")
subprocess.run(["ffmpeg","-y","-v","error",*inputs,"-filter_complex",";".join(filters),"-map","0:v","-map","[aout]",
  "-c:v","libx264","-preset","slow","-crf","20","-pix_fmt","yuv420p","-c:a","aac","-b:a","160k","-shortest",f"{out}/torque-demo.mp4"],check=True)
PY
echo "$OUT/torque-demo.mp4"
