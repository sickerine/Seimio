#!/bin/bash
# usage: summarize.sh "<experiment>"  -> one line: dropped, frame gaps, latency, GPU raster and GPU draw totals
n="$1"; f="d-$(echo "$n" | tr -cd 'a-z0-9')".json
node diag.mjs "$n" "$f" >/dev/null && python3 - "$f" "$n" <<'PY'
import sys, re, subprocess
out = subprocess.run(['python3', 'diag.py', sys.argv[1]], capture_output=True, text=True).stdout
lines = out.splitlines()
fr = [l for l in lines if l.startswith('frames')][0].split()
pres, drop = int(fr[2]), int(fr[4])
lat = next((l.split()[0] for l in lines if 'SubmitCompositorFrameToPresentation' in l), '?')
gp = next((l for l in lines if l.startswith('present gaps')), '')
m = re.search(r'p95 ([\d.]+).*>25ms (\d+)  >40ms (\d+)', gp)
p95, g25, g40 = (m.group(1), m.group(2), m.group(3)) if m else ('?', '?', '?')
def tot(k):
    for l in lines:
        if k in l:
            return float(l.split()[0])
    return 0.0
print('%5.1f%% dropped  gap p95 %5s ms  >25ms %3s  >40ms %3s  latency %6s ms  raster %5.0f  gpu-draw %5.0f  %s' % (
    100.0 * drop / max(1, pres + drop), p95, g25, g40, lat, tot('ExecuteDeferredRequest'), tot('FinishPaintCurrentFrame'), sys.argv[2]))
PY
