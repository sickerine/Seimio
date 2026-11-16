"""Summarise frame gaps (ms) per scenario from a QML lab report."""
import json, sys, collections
r = json.load(open(sys.argv[1]))
print('screen', r['screen'], 'refresh', r.get('refresh'))
for name, g in r['results'].items():
    if r.get("ticks"): print(name, "animation ticks", r["ticks"].get(name))
    if not g: print(name, 'no frames'); continue
    s = sorted(g); n = len(g); secs = sum(g) / 1000
    hist = collections.Counter(min(x, 60) for x in g)
    top = ' '.join(f'{k}:{v}' for k, v in sorted(hist.items()) if v >= 3)
    print(f"{name:14s} frames {n:5d} in {secs:4.1f}s = {n/secs:5.1f} fps  median {s[n//2]} ms  >20ms {sum(x>20 for x in g)/secs:5.2f}/s  >30ms {sum(x>30 for x in g)/secs:4.2f}/s  max {s[-1]}")
    print(f"{'':14s} gap histogram ms:count  {top}")
