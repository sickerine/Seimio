#!/bin/bash
# Relaunches the app on the TV, drives a route with the network remote, and prints frame pacing per
# phase (render-thread stamps from LabProbe). Routes: home (Continue Watching, tabs, a movie's title
# page), calendar (entering it, moving, scrolling into the next month, a day opening and turning,
# leaving), show (a show page), menu (quick actions opening and closing on a timer), play (an SDR episode
# from a show page: the loading screen, then the video with the controls over it; an HDR or Dolby Vision
# video would leave the panel at 48 Hz after it, which LG keeps until an SDR video plays), streams (a show's stream
# list, opened by the lab 12 s after launch: scrolling, filtering, leaving), player (an SDR episode's
# overlay: the transport, seeking, the Audio and Subtitles lists, the Streams sheet, the episode row;
# nothing is chosen, so no track choice is saved).
# Tours never call the AI pick ("noAi": the app gets no OpenRouter key and plays the best stream by rank).
# usage: [VARIANT='{"timing": true}'] tools/tour.sh home|calendar|show|menu|play|streams|player   (VARIANT: LabProbe switches)
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
export PATH=~/.nvm/versions/node/v20.20.0/bin:$PATH
id=$(python3 -c "import json;print(json.load(open('app/appinfo.json'))['id'])")
route=${1:-home}
mkdir -p .lab/www
python3 -c 'import json,sys; v = json.loads(sys.argv[1] or "{}"); v["noAi"] = True; v.update({"autopop": True} if sys.argv[2] == "menu" else {"openStreams": 12000} if sys.argv[2] == "streams" else {}); print(json.dumps(v))' "${VARIANT:-}" "$route" > .lab/www/variant.json
failed=0
# 8 s: the catalog loads and the calendar's art decodes for about 5 s after launch; that's startup, not
# what a tour measures
ares-launch -d tv --close "$id" >/dev/null 2>&1; ares-launch -d tv "$id" >/dev/null || { echo "  launch failed"; failed=1; }; sleep 8
N=~/.nvm/versions/node/v22.22.0/bin/node; S=$(date +%s)
p() { $N tools/tvremote.mjs press $1 ${2:-1} ${3:-350} 2>&1 | grep -q sent || { echo "  press $1 failed"; failed=1; }; }
case $route in
  home) p RIGHT 6 300; p LEFT 4 300; p UP 1 900; p RIGHT 3 400; p LEFT 3 400; p DOWN 1 900
        p RIGHT 2 600; p ENTER 1 1500; p RIGHT 2 400; p BACK 1 1500 ;;
  calendar) p DOWN 1 1500; p RIGHT 4 300; p LEFT 3 300; p ENTER 1 1800; p RIGHT 4 400; p RIGHT 6 300; p RIGHT 1 1500
        p BACK 1 1500; p DOWN 2 500; p DOWN 1 1500; p LEFT 3 300; p UP 6 500; p UP 1 1500 ;;
  show) p RIGHT 1 600; p ENTER 1 1500; p RIGHT 2 400; p DOWN 1 600; p LEFT 1 900; p RIGHT 1 900; p DOWN 1 600
        p RIGHT 4 350; p LEFT 2 350; p UP 1 600; p UP 1 600; p BACK 1 1500 ;;
  menu) sleep 15 ;;
  play) p RIGHT 3 1500; p ENTER 1 2500; p DOWN 2 900; p LEFT 1 900; p ENTER 1 14000; p RIGHT 1 1500; p LEFT 1 3000; p BACK 1 2500 ;;
  player) p RIGHT 3 1500; p ENTER 1 2500; p DOWN 2 900; p LEFT 1 900; p ENTER 1 14000
          p DOWN 1 900; p RIGHT 3 250; p LEFT 2 1300; p UP 1 900; p ENTER 1 1200; p DOWN 1 400; p BACK 1 900
          p RIGHT 1 400; p ENTER 1 1200; p DOWN 3 300; p BACK 1 900; p RIGHT 1 400; p ENTER 1 1500; p DOWN 4 300; p BACK 1 900
          p DOWN 1 900; p DOWN 1 1200; p RIGHT 2 500; p UP 1 900; p BACK 1 900; p BACK 1 2500 ;;
  streams) p RIGHT 1 5000; p DOWN 6 350; p UP 3 350; p UP 1 900; p LEFT 1 1200; p RIGHT 1 1200; p DOWN 1 600; p DOWN 4 350; p BACK 1 2000 ;;
esac
sleep 4; echo '{}' > .lab/www/variant.json
python3 - .lab/reports $S $route <<'PY'
# Budget, from the measurements after the 2026-11-16 performance pass (home had 17 late before it):
# at most 8 frames over 20 ms in the whole tour, and outside "idle" (which includes the launch) at most
# 2 over 30 ms and none over 60 ms. Over budget prints why and exits 1.
# The player route works the overlay over a playing video, and there the TV itself costs frames: on
# 2026-11-17 it measured 24-37 frames over 20 ms and 16-25 over 30 ms whatever the app did (with the
# tee and the subtitles off too; our handlers took under 5 ms and no JS collection ran). Its budget
# is that measurement: 40 over 20 ms, frames up to 150 ms; a regression shows above it. The play route
# seeks with the transport over the video too, so it has the same budget.
import json, os, sys, collections
d, s, route = sys.argv[1], sys.argv[2], sys.argv[3]
budget20, budgetMax = (40, 150) if route in ("player", "play") else (8, 60)
agg = collections.defaultdict(lambda: [0, 0, 0, 0])
for f in sorted(os.listdir(d)):
    if 'design' not in f or os.path.getmtime(os.path.join(d, f)) < float(s): continue   # this run's reports only
    for k, v in json.load(open(os.path.join(d, f))).items():
        if k.startswith('rt '): a = agg[k]; a[0] += v['frames']; a[1] += v['late20']; a[2] += v['late30']; a[3] = max(a[3], v['max'])
tot = [0, 0, 0]
for k, a in sorted(agg.items()):
    print(f"  {k[3:]:18s} frames {a[0]:4d}  late>20ms {a[1]:3d}  late>30ms {a[2]:3d}  worst {a[3]:4.0f} ms")
    tot[0] += a[0]; tot[1] += a[1]; tot[2] += a[2]
print(f"  {'total':18s} frames {tot[0]:4d}  late>20ms {tot[1]:3d}  late>30ms {tot[2]:3d}")
busy = [(k[3:], a) for k, a in agg.items() if k != 'rt idle']
over = []
if not tot[0]: over.append("no frame reports (is tools/lab-server.py running?)")
if tot[1] > budget20: over.append(f"{tot[1]} frames over 20 ms (budget {budget20})")
late30 = sum(a[2] for _, a in busy)
if late30 > 2: over.append(f"{late30} frames over 30 ms outside idle (budget 2)")
over += [f"{k}: a {a[3]:.0f} ms frame (budget {budgetMax})" for k, a in busy if a[3] > budgetMax]
for o in over: print("  OVER BUDGET:", o)
sys.exit(1 if over else 0)
PY
ok=$?
[ "$route" = menu ] && { ares-launch -d tv --close "$id" >/dev/null 2>&1; ares-launch -d tv "$id" >/dev/null || failed=1; }
[ $ok = 0 ] && [ $failed = 0 ]
