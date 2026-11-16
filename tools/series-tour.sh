#!/bin/bash
# Opens Dexter: Resurrection from Continue Watching and walks the show page with the remote; prints pacing per action.
D=$(cd "$(dirname "$0")" && pwd); echo '{}' > $D/www/variant.json
export PATH=~/.nvm/versions/node/v20.20.0/bin:$PATH
ares-launch -d tv --close lab.design.qml >/dev/null 2>&1; ares-launch -d tv lab.design.qml >/dev/null; sleep 5
cd ~/Documents/Github/stremio-webos/lab; N=~/.nvm/versions/node/v22.22.0/bin/node; S=$(date +%H%M%S)
p() { $N tvremote.mjs press $1 ${2:-1} ${3:-400} 2>&1 | grep -q sent || echo "press $1 failed"; }
p RIGHT 1 600; p ENTER 1 1500; p RIGHT 2 400; p DOWN 1 600; p LEFT 1 900; p RIGHT 1 900; p DOWN 1 600; p RIGHT 4 350; p LEFT 2 350; p UP 1 600; p UP 1 600; p BACK 1 1500; sleep 4
python3 - $D/reports $S <<'PY'
import json, os, sys, collections
d, s = sys.argv[1], sys.argv[2]
agg = collections.defaultdict(lambda: [0, 0, 0, 0])
for f in sorted(os.listdir(d)):
    if 'design' not in f or f < s: continue
    for k, v in json.load(open(os.path.join(d, f))).items():
        if k.startswith('rt '): a = agg[k]; a[0] += v['frames']; a[1] += v['late20']; a[2] += v['late30']; a[3] = max(a[3], v['max'])
for k, a in sorted(agg.items()): print(f"  {k[3:]:18s} frames {a[0]:4d} late>20 {a[1]:3d} late>30 {a[2]:3d} worst {a[3]:.0f} ms")
PY
