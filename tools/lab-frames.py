"""Per phase, how many frames were slow and where their time went: total, sync, render and swap ms, and
how many render passes (layers, glass and frost captures) each one drew. It needs Qt's render loop and
renderer timing in the lab log:
  VARIANT='{"timing":"qt.scenegraph.time.renderloop.debug=true\\nqt.scenegraph.time.renderer.debug=true"}'
Reading it: many passes, capture-bound; long render with few passes, draw-call bound; short render with
long GUI stalls (tools/lab-timeline.py), JavaScript-bound.

usage: python3 -I tools/lab-frames.py [since epoch seconds, default: 10 min ago]"""
import collections, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
lab_log = import_module("lab-timeline").lab_log


def main():
    since = float(sys.argv[1]) if len(sys.argv) > 1 else time.time() - 600
    passes, by_phase = 0, collections.defaultdict(list)
    for line in lab_log(since):
        phase = line.split(" | ")[0]
        if "time in renderer" in line: passes += 1
        elif "Frame rendered" in line:
            total, sync, render, swap = map(int, re.search(r"in (\d+)ms, sync=(\d+), render=(\d+), swap=(\d+)", line).groups())
            by_phase[phase].append((total, sync, render, swap, passes))
            passes = 0
    for phase, frames in sorted(by_phase.items()):
        slow = [f for f in frames if f[0] > 20]
        print(f"{phase:16s} {len(slow):3d}/{len(frames):4d} slow   first slow (total, sync, render, swap, passes): {slow[:6]}")


if __name__ == "__main__":
    main()
