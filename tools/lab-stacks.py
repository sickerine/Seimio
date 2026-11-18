"""What the GUI thread ran in each of its stalls: LabProbe's samples of it (one every 4 ms while it runs),
grouped by the stall they fall in, each as its innermost frames, and the key press before it. Run the tour
with VARIANT='{"timing": true, "sample": true}'. A frame named "?" is JavaScript the engine compiled.

usage: python3 -I tools/lab-stacks.py [since epoch seconds, default: 10 min ago] [min busy ms, default 12] [frames a sample, default 7]"""
import collections, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
timeline = import_module("lab-timeline")


def main():
    since = float(sys.argv[1]) if len(sys.argv) > 1 else time.time() - 600
    least = float(sys.argv[2]) if len(sys.argv) > 2 else 12
    depth = int(sys.argv[3]) if len(sys.argv) > 3 else 7
    t0, key, samples, stalls = None, "launch", [], []
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
        elif rest.startswith("gui stall"):
            gap, busy = float(rest.split()[2]), float(rest.split()[-1])
            # the heartbeat and the animation tick both report a stall: the one already listed covers this one
            if busy >= least and not (stalls and t - gap < stalls[-1][0]): stalls.append((t, gap, busy, phase, key))
    samples.sort()
    for t, gap, busy, phase, key in stalls:
        print(f"{t - t0:8.0f}  stall {gap:.0f} ms, busy {busy:.0f}  [{phase}]  after {key}")
        inside = collections.Counter(" < ".join(frames[:depth]) for at, frames in samples if t - gap - 4 <= at <= t)
        for stack, n in inside.most_common(): print(f"          {n:2d}  {stack}")


if __name__ == "__main__":
    main()
