"""What the GUI thread ran in each of its stalls, and waited in when a tick came late without work:
LabProbe's samples of it (one every 4 ms while it runs or is overdue), grouped by the stall or wait they
fall in, each as its innermost frames, and the key press before it. Pass 0 as the least busy ms to see waits. Run the tour
with VARIANT='{"timing": true, "sample": true}'. A frame named "?" is JavaScript the engine compiled.

usage: python3 -I tools/lab-stacks.py [since epoch seconds, default: 10 min ago] [min busy ms, default 12] [frames a sample, default 7]"""
import collections, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
timeline = import_module("lab-timeline")
RANK = {"stall": 0, "waited": 1, "tick": 2}         # what the heartbeat says comes before the animation tick's word
NAMES = ["stall", "wait", "late tick"]


def main():
    since = float(sys.argv[1]) if len(sys.argv) > 1 else time.time() - 600
    least = float(sys.argv[2]) if len(sys.argv) > 2 else 12
    depth = int(sys.argv[3]) if len(sys.argv) > 3 else 7
    t0, key, samples, found = None, "launch", [], []
    for line in timeline.lab_log(since):
        try:
            phase, body = line.split(" | ", 1)
            stamp, rest = body.split(" ", 1)
            t = float(stamp)
        except ValueError:
            continue
        t0 = t0 or t
        if rest.startswith("key "): key = f"{timeline.KEYS.get(rest.split()[-1], rest)} at {t - t0:.0f}"
        elif rest.startswith("stack "): samples.append((t, rest[6:].split(" < ")))
        elif rest.startswith(("gui stall", "gui waited", "gui tick")):
            try: gap, busy = float(rest.split()[2]), float(rest.split()[-1])
            except ValueError: continue                 # (a line an older build wrote another way)
            found.append([t - gap, t, busy, RANK[rest.split()[1]], phase, key])
    # the heartbeat (stall, waited) and the animation tick report the same stretch: one entry for it, the
    # whole of it, called what the heartbeat called it
    found.sort()
    spans = []
    for f in found:
        if spans and f[0] < spans[-1][1]:
            last = spans[-1]
            last[1], last[2], last[3] = max(last[1], f[1]), max(last[2], f[2]), min(last[3], f[3])
        else: spans.append(f)
    samples.sort()
    for start, end, busy, rank, phase, key in spans:
        if busy < least: continue
        print(f"{end - t0:8.0f}  {NAMES[rank]} {end - start:.0f} ms, busy {busy:.0f}  [{phase}]  after {key}")
        inside = collections.Counter(" < ".join(frames[:depth]) for at, frames in samples if start - 4 <= at <= end)
        for stack, n in inside.most_common(): print(f"          {n:2d}  {stack}")


if __name__ == "__main__":
    main()
