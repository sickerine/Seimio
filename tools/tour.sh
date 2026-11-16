#!/bin/bash
# Relaunches the app on the TV, drives a route with the network remote, and prints frame pacing per
# phase (render-thread stamps from LabProbe). Routes: home (rows, tabs, sheet), show (a show page),
# menu (quick actions opening and closing on a timer).
# usage: [VARIANT='{"timing": true}'] tools/tour.sh home|show|menu   (VARIANT: LabProbe switches)
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
export PATH=~/.nvm/versions/node/v20.20.0/bin:$PATH
id=$(python3 -c "import json;print(json.load(open('app/appinfo.json'))['id'])")
route=${1:-home}
mkdir -p .lab/www
python3 -c 'import json,sys; v = json.loads(sys.argv[1] or "{}"); v.update({"autopop": True} if sys.argv[2] == "menu" else {}); print(json.dumps(v))' "${VARIANT:-}" "$route" > .lab/www/variant.json
ares-launch -d tv --close "$id" >/dev/null 2>&1; ares-launch -d tv "$id" >/dev/null; sleep 5
N=~/.nvm/versions/node/v22.22.0/bin/node; S=$(date +%H%M%S)
p() { $N tools/tvremote.mjs press $1 ${2:-1} ${3:-350} 2>&1 | grep -q sent || echo "press $1 failed"; }
case $route in
  home) p RIGHT 8 300; p DOWN 1 900; p RIGHT 5 300; p LEFT 3 300; p UP 1 900; p UP 1 700; p RIGHT 3 400; p DOWN 1 700
        p DOWN 1 700; p ENTER 1 1500; p RIGHT 2 400; p BACK 1 1500 ;;
  show) p RIGHT 1 600; p ENTER 1 1500; p RIGHT 2 400; p DOWN 1 600; p LEFT 1 900; p RIGHT 1 900; p DOWN 1 600
        p RIGHT 4 350; p LEFT 2 350; p UP 1 600; p UP 1 600; p BACK 1 1500 ;;
  menu) sleep 15 ;;
esac
sleep 4; echo '{}' > .lab/www/variant.json
python3 - .lab/reports $S <<'PY'
import json, os, sys, collections
d, s = sys.argv[1], sys.argv[2]
agg = collections.defaultdict(lambda: [0, 0, 0, 0])
for f in sorted(os.listdir(d)):
    if 'design' not in f or f < s: continue
    for k, v in json.load(open(os.path.join(d, f))).items():
        if k.startswith('rt '): a = agg[k]; a[0] += v['frames']; a[1] += v['late20']; a[2] += v['late30']; a[3] = max(a[3], v['max'])
tot = [0, 0, 0]
for k, a in sorted(agg.items()):
    print(f"  {k[3:]:18s} frames {a[0]:4d}  late>20ms {a[1]:3d}  late>30ms {a[2]:3d}  worst {a[3]:4.0f} ms")
    tot[0] += a[0]; tot[1] += a[1]; tot[2] += a[2]
print(f"  {'total':18s} frames {tot[0]:4d}  late>20ms {tot[1]:3d}  late>30ms {tot[2]:3d}")
PY
[ "$route" = menu ] && { ares-launch -d tv --close "$id" >/dev/null 2>&1; ares-launch -d tv "$id" >/dev/null; }
true
