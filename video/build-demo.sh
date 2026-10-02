#!/usr/bin/env bash
# Builds the Demo Video: narration (macOS say) + recorded run of the site + mux.
#   SITE_URL=... RPC=... PK=... ./build-demo.sh out_dir
set -euo pipefail
OUT="$(cd "${1:-out}" 2>/dev/null && pwd || (mkdir -p "${1:-out}" && cd "${1:-out}" && pwd))"
HERE="$(cd "$(dirname "$0")" && pwd)"
VOICE="${VOICE:-Samantha}"
if [ -n "${NARRATION_MP3:-}" ]; then
  # one ElevenLabs MP3 for the whole video, split at the long pauses between shots
  python3 "$HERE/split_narration.py" "$HERE/demo-narration.json" "$NARRATION_MP3" "$OUT" n
else
  python3 - "$HERE/demo-narration.json" "$OUT" "$VOICE" <<'PY'
import json, re, subprocess, sys
steps=json.load(open(sys.argv[1])); out=sys.argv[2]; voice=sys.argv[3]; d={}
for s in steps:
    wav=f"{out}/n_{s['id']}.wav"; aiff=f"{out}/n_{s['id']}.aiff"
    text=re.sub(r"\[[^\]]*\]","",s["text"])
    subprocess.run(["say","-v",voice,"-r","182","-o",aiff,text],check=True)
    subprocess.run(["ffmpeg","-y","-i",aiff,wav],check=True,capture_output=True)
    d[s["id"]]=float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",wav]).decode())
json.dump(d,open(f"{out}/durations.json","w"),indent=1)
PY
fi
OUT="$OUT" node "$HERE/demo.js" | tee "$OUT/run.log"
VIDEO=$(grep '^video ' "$OUT/run.log" | awk '{print $2}')
python3 - "$OUT" "$VIDEO" <<'PY'
import json, subprocess, sys
out, video = sys.argv[1], sys.argv[2]
marks=json.load(open(f"{out}/marks.json"))
inputs=["-i",video]; filters=[]; labels=""
for i,m in enumerate(marks):
    inputs+=["-i",f"{out}/n_{m['id']}.wav"]
    ms=int(m["start"]*1000)
    filters.append(f"[{i+1}:a]adelay={ms}|{ms}[a{i}]"); labels+=f"[a{i}]"
filters.append(f"{labels}amix=inputs={len(marks)}:normalize=0[aout]")
subprocess.run(["ffmpeg","-y",*inputs,"-filter_complex",";".join(filters),"-map","0:v","-map","[aout]",
  "-c:v","libx264","-preset","slow","-crf","20","-pix_fmt","yuv420p","-c:a","aac","-b:a","160k","-shortest",f"{out}/torque-demo.mp4"],check=True)
PY
echo "$OUT/torque-demo.mp4"
