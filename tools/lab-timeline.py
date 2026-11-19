"""Prints, in time order, the key presses, the GUI thread's stalls, waits and late animation ticks, and the late frames LabProbe logged into the lab
reports (.lab/reports). It needs LogTap on: run the tour with VARIANT='{"timing": ...}'. A stall a fixed
time after a key (e.g. 280 ms, when the selection commits) points at what that press set off.

usage: python3 -I tools/lab-timeline.py [since epoch seconds, default: 10 min ago] [min ms, default 25]"""
import json, os, sys, time

REPORTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".lab", "reports")
KEYS = {"1000015": "DOWN", "1000013": "UP", "1000012": "LEFT", "1000014": "RIGHT", "1000004": "OK", "1200003": "BACK"}


def lab_log(since):
    """The log lines of every report written since `since`, in order."""
    out = []
    for f in sorted(os.listdir(REPORTS), key=lambda f: os.path.getmtime(os.path.join(REPORTS, f))):
        path = os.path.join(REPORTS, f)
        if not f.endswith("-log.json") or os.path.getmtime(path) < since: continue
        try: out += json.load(open(path)).get("log", [])
        except ValueError: pass
    return out


def main():
    since = float(sys.argv[1]) if len(sys.argv) > 1 else time.time() - 600
    least = float(sys.argv[2]) if len(sys.argv) > 2 else 25
    t0 = None
    for line in lab_log(since):
        try:
            phase, body = line.split(" | ", 1)
            stamp, rest = body.split(" ", 1)
            t = float(stamp)
        except ValueError:
            continue
        t0 = t0 or t
        if rest.startswith("key "): print(f"{t - t0:8.0f}  {KEYS.get(rest.split()[-1], rest)}")
        elif rest.startswith(("gui stall", "gui waited", "gui tick", "late frame", "swap held")) and rest.split()[2].replace(".", "").isdigit() and float(rest.split()[2]) >= least: print(f"{t - t0:8.0f}      {rest}   [{phase}]")


if __name__ == "__main__":
    main()
