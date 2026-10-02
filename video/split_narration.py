#!/usr/bin/env python3
"""Split one narration MP3 (all shots, separated by [long pause]) into one clip per shot.

    python3 split_narration.py <narration.json> <voice.mp3> <out_dir> <prefix>

Finds the N-1 longest silences (N = number of shots), cuts in the middle of each, trims edge silence,
writes <out_dir>/<prefix>_<id>.wav and <out_dir>/durations.json, and prints each shot's duration next to
an estimate from its word count so a bad split is obvious before any video is built.
"""
import json, re, subprocess, sys

spec, mp3, out, prefix = sys.argv[1:5]
shots = json.load(open(spec))
n = len(shots)

def probe(path):
    return float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]).decode())

total = probe(mp3)
log = subprocess.run(["ffmpeg", "-i", mp3, "-af", "silencedetect=noise=-38dB:d=0.3", "-f", "null", "-"],
                     capture_output=True, text=True).stderr
starts = [float(x) for x in re.findall(r"silence_start: ([\d.]+)", log)]
ends = [float(x) for x in re.findall(r"silence_end: ([\d.]+)", log)]
gaps = [(s, e) for s, e in zip(starts, ends) if s > 0.5 and e < total - 0.5]
if len(gaps) < n - 1:
    sys.exit(f"found {len(gaps)} pauses, need {n-1}: the MP3 does not have a pause between every shot")

# Expected share of the running time for each shot, from its word count.
def est(t):
    return len(re.sub(r"\[[^\]]*\]", "", t).split()) / 2.55 + t.count("[pause]") * 0.6
weights = [est(s["text"]) for s in shots]
frac = [w / sum(weights) for w in weights]

# Choose N-1 cut silences (in order) that are long AND leave shots near their expected lengths.
# score = sum(silence lengths) - 25 * sum(|actual share - expected share|)
import functools
G = len(gaps)
mid = [(a + b) / 2 for a, b in gaps]
length = [b - a for a, b in gaps]

@functools.lru_cache(maxsize=None)
def best(k, j):
    """Best score placing cut k (0-based) at gap j, covering shots 0..k."""
    start = 0.0 if k == 0 else None
    if k == 0:
        return (length[j] - 25 * abs((mid[j] - 0.0) / total - frac[0]), (j,))
    top = None
    for i in range(k - 1, j):
        sc, path = best(k - 1, i)
        sc += length[j] - 25 * abs((mid[j] - mid[i]) / total - frac[k])
        if top is None or sc > top[0]:
            top = (sc, path + (j,))
    return top

final = None
for j in range(n - 2, G):
    sc, path = best(n - 2, j)
    sc -= 25 * abs((total - mid[j]) / total - frac[n - 1])
    if final is None or sc > final[0]:
        final = (sc, path)
cuts = [gaps[j] for j in final[1]]
bounds = [0.0] + [(a + b) / 2 for a, b in cuts] + [total]
chosen = sorted(length[j] for j in final[1])
others = sorted((length[j] for j in range(G) if j not in final[1]), reverse=True)
if others and chosen and others[0] > chosen[0]:
    print(f"note: a {others[0]:.2f}s pause inside a shot is longer than the shortest cut pause ({chosen[0]:.2f}s); "
          "cuts were chosen by expected shot lengths, check the first words below")

durations = {}
print(f"{'shot':10} {'start':>7} {'dur':>6} {'est':>6}  first words")
for i, s in enumerate(shots):
    a, b = bounds[i], bounds[i + 1]
    raw = f"{out}/{prefix}_{s['id']}.raw.wav"
    clip = f"{out}/{prefix}_{s['id']}.wav"
    subprocess.run(["ffmpeg", "-y", "-ss", f"{a:.3f}", "-to", f"{b:.3f}", "-i", mp3, "-ac", "1", "-ar", "44100", raw],
                   check=True, capture_output=True)
    trim = ("silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.12,"
            "areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.25,areverse")
    subprocess.run(["ffmpeg", "-y", "-i", raw, "-af", trim, clip], check=True, capture_output=True)
    d = probe(clip)
    durations[s["id"]] = d
    words = len(re.sub(r"\[[^\]]*\]", "", s["text"]).split())
    est = words / 2.55 + s["text"].count("[pause]") * 0.6
    flag = "  <-- check" if abs(d - est) > max(4.0, 0.35 * est) else ""
    spoken = re.sub(r"\[[^\]]*\]", "", s["text"]).split()[:6]
    print(f"{s['id']:10} {a:7.2f} {d:6.2f} {est:6.1f}  {' '.join(spoken)}{flag}")
json.dump(durations, open(f"{out}/durations.json", "w"), indent=1)
