#!/bin/bash
# Relaunches the app on the TV, drives a route with the network remote, and prints frame pacing per
# phase (render-thread stamps from LabProbe). Routes: home (Continue Watching, tabs, a movie's title
# page), calendar (entering it, moving, scrolling into the next month, a day opening, one of its
# releases opening its show page and closing, the day turning, leaving; the calendar is the library's, so
# the days its keys land on may be empty or have one release, which opens its page: the day view is
# only walked when the library has two shows out on one of them), show (a show page: it opens
# resting on an episode; the episodes, a season change, the actions), menu (quick actions opening and
# closing on a timer), play (an SDR episode from a show page: the loading screen, then the video with
# the controls over it; an HDR or Dolby Vision video would leave the panel at 48 Hz after it, which LG
# keeps until an SDR video plays), streams (a show's stream list, opened by the lab 12 s after the app
# starts: scrolling, filtering, leaving; its keys wait 16 s from the launch, since at 13 s an app a
# second slow to start had them on Home instead), player (an SDR episode's overlay: the transport, seeking, the Audio
# and Subtitles lists, the Streams sheet, the episode row; nothing is chosen, so no track choice is
# saved), anime (the Anime tab: moving along the chart crossfades its fanart; a show opening and
# closing; the filters walked, one chosen and undone), schedule (the Anime tab's schedule: down through
# the days and along them), browse (the Movies tab: into its rows, along and down them, a film opening and
# closing; then Series and the Library, each walked a little), search (the lab types "demon slayer" and
# enters it: along its first row, down a row, a title opening and closing, up to the kinds, another kind
# picked and walked, the first picked again; not in check.sh, since the TV's keyboard sliding in as the
# lab types makes the frames under it late). Tours never call the AI pick ("noAi": the app gets no OpenRouter key and
# plays the best stream by rank) and never tell Stremio what they played ("unreported": the account's own
# progress stays where it was).
# usage: [VARIANT='{"timing": true}'] tools/tour.sh home|calendar|show|menu|play|streams|player|anime|schedule|browse|search   (VARIANT: LabProbe switches)
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
export PATH=~/.nvm/versions/node/v20.20.0/bin:$PATH
id=$(python3 -c "import json;print(json.load(open('app/appinfo.json'))['id'])")
route=${1:-home}
mkdir -p .lab/www
python3 -c 'import json,sys; v = json.loads(sys.argv[1] or "{}"); v["noAi"] = True; v["unreported"] = True; v.update({"autopop": True} if sys.argv[2] == "menu" else {"openStreams": 12000} if sys.argv[2] == "streams" else {"search": "demon slayer"} if sys.argv[2] == "search" else {}); print(json.dumps(v))' "${VARIANT:-}" "$route" > .lab/www/variant.json
failed=0
# 8 s: the catalog loads and the calendar's art decodes for about 5 s after launch; that's startup, not
# what a tour measures
ares-launch -d tv --close "$id" >/dev/null 2>&1; ares-launch -d tv "$id" >/dev/null || { echo "  launch failed"; failed=1; }; sleep 8
N=~/.nvm/versions/node/v22.22.0/bin/node; S=$(date +%s)
p() { $N tools/tvremote.mjs press $1 ${2:-1} ${3:-350} 2>&1 | grep -q sent || { echo "  press $1 failed"; failed=1; }; }
case $route in
  home) p RIGHT 6 300; p LEFT 4 300; p UP 1 900; p RIGHT 3 400; p LEFT 3 400; p DOWN 1 900
        p RIGHT 2 600; p ENTER 1 1500; p RIGHT 2 400; p BACK 1 1500 ;;
  calendar) p DOWN 1 1500; p RIGHT 4 300; p LEFT 3 300; p ENTER 1 1800; p ENTER 1 2000; p BACK 1 1500; p RIGHT 4 400; p RIGHT 6 300; p RIGHT 1 1500
        p BACK 1 1500; p DOWN 2 500; p DOWN 1 1500; p LEFT 3 300; p UP 6 500; p UP 1 1500 ;;
  show) p RIGHT 1 600; p ENTER 1 1500; p RIGHT 4 350; p LEFT 2 350; p UP 1 600; p LEFT 1 900; p RIGHT 1 900
        p DOWN 1 600; p UP 2 600; p RIGHT 2 400; p DOWN 2 600; p BACK 1 1500 ;;
  menu) sleep 15 ;;
  play) p RIGHT 3 1500; p ENTER 1 2500; p LEFT 1 900; p ENTER 1 14000; p RIGHT 1 1500; p LEFT 1 3000; p BACK 1 2500 ;;
  player) p RIGHT 3 1500; p ENTER 1 2500; p LEFT 1 900; p ENTER 1 14000
          p DOWN 1 900; p RIGHT 3 250; p LEFT 2 1300; p UP 1 900; p ENTER 1 1200; p DOWN 1 400; p BACK 1 900
          p RIGHT 1 400; p ENTER 1 1200; p DOWN 3 300; p BACK 1 900; p RIGHT 1 400; p ENTER 1 1500; p DOWN 4 300; p BACK 1 900
          p DOWN 1 900; p DOWN 1 1200; p RIGHT 2 500; p UP 1 900; p BACK 1 900; p BACK 1 2500 ;;
  streams) p RIGHT 1 8000; p DOWN 6 350; p UP 3 350; p UP 1 900; p LEFT 1 1200; p RIGHT 1 1200; p DOWN 1 600; p DOWN 4 350; p BACK 1 2000 ;;
  schedule) p UP 1 900; p RIGHT 1 2500; p DOWN 1 900; p RIGHT 1 400; p ENTER 1 2000; p DOWN 1 1200; p RIGHT 3 400; p DOWN 1 900
            p DOWN 1 900; p DOWN 1 900; p RIGHT 2 400; p UP 1 900; p UP 1 900; p DOWN 3 500; p UP 4 600 ;;
  browse) p UP 1 900; p RIGHT 2 2000; p DOWN 1 900; p DOWN 1 900; p RIGHT 3 350; p DOWN 3 700; p UP 2 700; p ENTER 1 2000; p BACK 1 1500
          p BACK 1 900; p UP 1 900; p RIGHT 1 2000; p DOWN 2 900; p RIGHT 2 400; p BACK 1 900; p UP 1 900; p RIGHT 1 2000; p DOWN 2 900; p RIGHT 3 350 ;;
  anime) p UP 1 900; p RIGHT 1 2500; p DOWN 2 900; p RIGHT 5 1200; p LEFT 3 1200; p ENTER 1 2500; p BACK 1 1500
         p UP 1 900; p RIGHT 3 300; p ENTER 1 1500; p LEFT 1 300; p ENTER 1 1500; p UP 1 900 ;;
  search) sleep 5; p RIGHT 4 350; p DOWN 1 900; p RIGHT 1 500; p UP 1 900; p LEFT 2 350; p ENTER 1 2500; p BACK 1 1500
          # up to the kinds, the one beside the chosen one picked and walked, then the first one picked
          # again: the account's own pick is what it was
          kind=$(python3 -c "import json,glob,os; print(json.load(open(sorted(glob.glob('.lab/reports/*design.json'), key=os.path.getmtime)[-1]))['state']['search']['kind'])")
          there=RIGHT; back=LEFT; [ "$kind" = movie ] && { there=LEFT; back=RIGHT; }
          p UP 1 900; p $there 1 700; p ENTER 1 2500; p DOWN 1 900; p RIGHT 2 350; p UP 1 900; p $back 1 700; p ENTER 1 2500; p DOWN 1 900; p BACK 1 1500 ;;
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
# A swap the TV's compositor held is not in any of these: Qt waits up to 100 ms for the compositor to
# acknowledge the frame before, and for one frame in about 11,000 no acknowledgement comes
# (FrameStats in native/src/probes.h has the measurements). It is printed on its own line, "the TV held".
import json, os, sys, collections
d, s, route = sys.argv[1], sys.argv[2], sys.argv[3]
budget20, budgetMax = (40, 150) if route in ("player", "play") else (8, 60)
# Frames with 12 ms and more of sync and render in them (`heavy`) are what a held swap follows, so they
# have a budget of their own. Measured on 2026-11-19 with the bars' glass on the backdrop's layers:
# home 5 to 11 a tour, browse 4 to 12, schedule 10, the others 1 to 3 (home had 21 to 24 before that
# change, which this budget fails); anime 12 to 22 and search 23, most of them in the launch, which
# both tours do more in (the Anime tab built at once, the search opened under the TV's keyboard).
budgetHeavy = {"anime": 30, "search": 32}.get(route, 20)
agg = collections.defaultdict(lambda: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
errors = []
for f in sorted(os.listdir(d)):
    if 'design' not in f or os.path.getmtime(os.path.join(d, f)) < float(s): continue   # this run's reports only
    report = json.load(open(os.path.join(d, f)))
    errors += [e for e in report.get('errors', []) if e not in errors]
    for k, v in report.items():
        if k.startswith('rt '):
            a = agg[k]; a[0] += v['frames']; a[1] += v['late20']; a[2] += v['late30']; a[3] = max(a[3], v['max'])
            a[4] += v.get('stalls', 0); a[5] = max(a[5], v.get('stallMax', 0))
            a[6] += v.get('held', 0); a[7] = max(a[7], v.get('heldMax', 0)); a[8] += v.get('heavy', 0); a[9] += v.get('missed', 0)
tot = [0, 0, 0, 0, 0]
for k, a in sorted(agg.items()):
    print(f"  {k[3:]:18s} frames {a[0]:4d}  late>20ms {a[1]:3d}  late>30ms {a[2]:3d}  worst {a[3]:4.0f} ms  gui stalls {a[4]:2d} (worst {a[5]:3.0f} ms)  heavy {a[8]:3d}  missed {a[9]:3d}")
    tot[0] += a[0]; tot[1] += a[1]; tot[2] += a[2]; tot[3] += a[8]; tot[4] += a[9] if k != 'rt idle' else 0
# (heavy: frames with 12 ms and more of sync and render in them, what a held swap follows: budgeted below.
# missed: frames drawn on time without the GUI thread's turn, so what it animates stood still for one
# (FrameStats in probes.h); the total leaves idle out, where nothing of the GUI thread's is moving)
print(f"  {'total':18s} frames {tot[0]:4d}  late>20ms {tot[1]:3d}  late>30ms {tot[2]:3d}  heavy {tot[3]:3d}  missed {tot[4]:3d}")
held = [(k[3:], a[6], a[7]) for k, a in sorted(agg.items()) if a[6]]
if held: print("  the TV held " + ", ".join(f"{n} swap{'s' if n > 1 else ''} in {k} ({w:.0f} ms)" for k, n, w in held) + ": its compositor's, not counted above")
busy = [(k[3:], a) for k, a in agg.items() if k != 'rt idle']
over = []
if not tot[0]: over.append("no frame reports (is tools/lab-server.py running?)")
# a handler that threw or a binding that read nothing: the app said so (LogTap.watch)
for e in errors: print("  ERROR " + e[:240])
if errors: over.append(f"{len(errors)} script error(s)")
if tot[1] > budget20: over.append(f"{tot[1]} frames over 20 ms (budget {budget20})")
if tot[3] > budgetHeavy: over.append(f"{tot[3]} frames with 12 ms or more of drawing (budget {budgetHeavy})")
# Measured on 2026-11-19: 1 to 6 a tour on the check's routes, and 10 to 18 on Home and browse while a
# picture's bands asked for their frames from the render thread (banded_image.h), which this fails.
if tot[4] > 8: over.append(f"{tot[4]} frames drawn without the GUI thread's turn while something moved (budget 8)")
late30 = sum(a[2] for _, a in busy)
if late30 > 2: over.append(f"{late30} frames over 30 ms outside idle (budget 2)")
over += [f"{k}: a {a[3]:.0f} ms frame (budget {budgetMax})" for k, a in busy if a[3] > budgetMax]
# GUI stalls (FrameStats' heartbeat: the GUI thread busy over 50 ms, drawing or not), the whole tour:
# measured 0 on every route on 2026-11-17 after the stream rows went asynchronous
stalls = sum(a[4] for a in agg.values()); worst = max([a[5] for a in agg.values()] or [0])
if stalls > 2: over.append(f"{stalls} GUI stalls over 50 ms (budget 2)")
if worst > 100: over.append(f"a {worst:.0f} ms GUI stall (budget 100)")
for o in over: print("  OVER BUDGET:", o)
sys.exit(1 if over else 0)
PY
ok=$?
[ "$route" = menu ] && { ares-launch -d tv --close "$id" >/dev/null 2>&1; ares-launch -d tv "$id" >/dev/null || failed=1; }
[ $ok = 0 ] && [ $failed = 0 ]
