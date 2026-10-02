#!/usr/bin/env bash
# Builds the Pitch Video: slide images (Playwright) + narration (macOS say) + ffmpeg.
#   ./build-pitch.sh out_dir [MARKET VAULT]
set -euo pipefail
mkdir -p "${1:-out}"; OUT="$(cd "${1:-out}" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
VOICE="${VOICE:-Samantha}"
MARKET="${2:-}"; VAULT="${3:-}"
node - "$HERE" "$OUT" "$MARKET" "$VAULT" <<'JS'
const { chromium } = require("playwright");
const fs = require("fs");
const [here, out, market, vault] = process.argv.slice(2);
const steps = JSON.parse(fs.readFileSync(here + "/pitch-narration.json"));
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1920, height: 1080 } });
  for (const s of steps) {
    const qs = new URLSearchParams({ s: s.id, ...(market ? { market, vault } : {}) });
    await p.goto("file://" + here + "/pitch/slides.html?" + qs, { waitUntil: "networkidle" });
    await p.waitForTimeout(400);
    await p.screenshot({ path: `${out}/slide_${s.id}.png` });
  }
  await b.close();
})();
JS
if [ -n "${NARRATION_MP3:-}" ]; then
  python3 "$HERE/split_narration.py" "$HERE/pitch-narration.json" "$NARRATION_MP3" "$OUT" p
else
  python3 - "$HERE/pitch-narration.json" "$OUT" "$VOICE" <<'PY'
import json, re, subprocess, sys
steps=json.load(open(sys.argv[1])); out=sys.argv[2]; voice=sys.argv[3]
for s in steps:
    aiff=f"{out}/p_{s['id']}.aiff"
    subprocess.run(["say","-v",voice,"-r","178","-o",aiff,re.sub(r"\[[^\]]*\]","",s["text"])],check=True)
    subprocess.run(["ffmpeg","-y","-i",aiff,f"{out}/p_{s['id']}.wav"],check=True,capture_output=True)
PY
fi
python3 - "$HERE/pitch-narration.json" "$OUT" <<'PY'
import json, subprocess, sys
steps=json.load(open(sys.argv[1])); out=sys.argv[2]
parts=[]
for s in steps:
    aiff=f"{out}/p_{s['id']}.wav"
    dur=float(subprocess.check_output(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",aiff]).decode())
    clip=f"{out}/c_{s['id']}.mp4"
    total=dur+1.0
    subprocess.run(["ffmpeg","-y","-loop","1","-t",f"{total:.2f}","-i",f"{out}/slide_{s['id']}.png","-i",aiff,
      "-filter_complex",f"[0:v]fade=t=in:st=0:d=0.35,fade=t=out:st={total-0.35:.2f}:d=0.35,format=yuv420p[v];[1:a]adelay=400|400,apad[a]",
      "-map","[v]","-map","[a]","-t",f"{total:.2f}","-r","30","-c:v","libx264","-preset","slow","-crf","18","-c:a","aac","-b:a","160k",clip],
      check=True,capture_output=True)
    parts.append(clip)
open(f"{out}/list.txt","w").write("".join(f"file '{p}'\n" for p in parts))
subprocess.run(["ffmpeg","-y","-f","concat","-safe","0","-i",f"{out}/list.txt","-c","copy",f"{out}/torque-pitch.mp4"],check=True,capture_output=True)
print(f"{out}/torque-pitch.mp4")
PY
