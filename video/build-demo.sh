#!/usr/bin/env bash
# Builds the Demo Video: narration (macOS say) + recorded run of the site + mux.
#   SITE_URL=... RPC=... PK=... ./build-demo.sh out_dir
set -euo pipefail
OUT="$(cd "${1:-out}" 2>/dev/null && pwd || (mkdir -p "${1:-out}" && cd "${1:-out}" && pwd))"
HERE="$(cd "$(dirname "$0")" && pwd)"
VOICE="${VOICE:-Samantha}"
python3 - "$HERE/demo-narration.json" "$OUT" "$VOICE" <<'PY'
import json, subprocess, sys
steps=json.load(open(sys.argv[1])); out=sys.argv[2]; voice=sys.argv[3]; d={}
for s in steps:
    aiff=f"{out}/n_{s['id']}.aiff"
    subprocess.run(["say","-v",voice,"-r","182","-o",aiff,s["text"]],check=True)
    d[s["id"]]=float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",aiff]).decode())
json.dump(d,open(f"{out}/durations.json","w"),indent=1)
PY
OUT="$OUT" node "$HERE/demo.js" | tee "$OUT/run.log"
VIDEO=$(grep '^video ' "$OUT/run.log" | awk '{print $2}')
python3 - "$OUT" "$VIDEO" <<'PY'
import json, subprocess, sys
out, video = sys.argv[1], sys.argv[2]
marks=json.load(open(f"{out}/marks.json"))
inputs=["-i",video]; filters=[]; labels=""
for i,m in enumerate(marks):
    inputs+=["-i",f"{out}/n_{m['id']}.aiff"]
    ms=int(m["start"]*1000)
    filters.append(f"[{i+1}:a]adelay={ms}|{ms}[a{i}]"); labels+=f"[a{i}]"
filters.append(f"{labels}amix=inputs={len(marks)}:normalize=0[aout]")
subprocess.run(["ffmpeg","-y",*inputs,"-filter_complex",";".join(filters),"-map","0:v","-map","[aout]",
  "-c:v","libx264","-preset","slow","-crf","20","-pix_fmt","yuv420p","-c:a","aac","-b:a","160k","-shortest",f"{out}/torque-demo.mp4"],check=True)
PY
echo "$OUT/torque-demo.mp4"
