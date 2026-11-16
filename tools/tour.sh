#!/bin/bash
# usage: tour.sh '<variant json>'  -> relaunches the design lab with that variant, drives the remote, prints per-action pacing
D=$(cd "$(dirname "$0")" && pwd); echo "$1" > $D/www/variant.json
export PATH=~/.nvm/versions/node/v20.20.0/bin:$PATH
ares-launch -d tv --close lab.design.qml >/dev/null 2>&1; ares-launch -d tv lab.design.qml >/dev/null; sleep 5
cd ~/Documents/Github/stremio-webos/lab; N=~/.nvm/versions/node/v22.22.0/bin/node; S=$(date +%H%M%S)
p() { $N tvremote.mjs press $1 ${2:-1} ${3:-350} 2>&1 | grep -q sent || echo "press $1 failed"; }
p RIGHT 8 300; p DOWN 1 900; p RIGHT 5 300; p LEFT 3 300; p UP 1 900; p UP 1 700; p RIGHT 3 400; p DOWN 1 700; p ENTER 1 1500; p RIGHT 2 400; p BACK 1 1500; p INFO 1 1200; p BACK 1 1000; sleep 4
python3 - $D/reports $S <<'PY'
import json, os, sys, collections, re
d, s = sys.argv[1], sys.argv[2]
agg = collections.defaultdict(lambda: {'frames': 0, 'late20': 0, 'late30': 0, 'max': 0}); lat = []
for f in sorted(os.listdir(d)):
    if 'design' not in f or f < s: continue
    r = json.load(open(os.path.join(d, f)))
    if r.get('keys'): print('unknown keys', r['keys'])
    m = re.search(r'arrival: n (\d+) median ([\d.]+) p90 ([\d.]+) max ([\d.]+)', r['latency'])
    if m: lat.append((int(m.group(1)), float(m.group(2)), float(m.group(4))))
    for k, v in r.items():
        if isinstance(v, dict) and 'frames' in v:
            a = agg[k]; a['frames'] += v['frames']; a['late20'] += v['late20']; a['late30'] += v['late30']; a['max'] = max(a['max'], v['max'])
print('key latency (app arrival to frame): medians', [l[1] for l in lat], 'worst', max([l[2] for l in lat] or [0]))
for k, a in sorted(agg.items()): print(f"  {k:16s} frames {a['frames']:5d}  late>20ms {a['late20']:3d}  late>30ms {a['late30']:3d}  worst {a['max']} ms")
PY
