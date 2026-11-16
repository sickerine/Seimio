"""Per frame: BeginFrame tick phase vs vsync, tick->present latency, and the gap to the previous present."""
import json, sys, collections
ev = json.load(open(sys.argv[1]))
pres = sorted(set(e['ts'] for e in ev if e['name'] == 'SwapEndToPresentationCompositorFrame' and e.get('ph') == 'e'))
ticks = sorted(e['args']['frame_time'] for e in ev if e['name'] == 'DelayBasedBeginFrameSource::OnTimerTick')
gaps = [(b - a) / 1000 for a, b in zip(pres, pres[1:]) if b - a < 100000]
n = [round(g / 8.3333) for g in gaps]
V = sum(gaps) / sum(n)
import bisect
rows = []
for i in range(1, len(pres)):
    p = pres[i]
    j = bisect.bisect_left(ticks, p - 4000) - 1   # tick that started this frame (at least 4 ms before present)
    if j < 0: continue
    t = ticks[j]
    rows.append(((t - pres[0]) / 1000 % V, (p - t) / 1000, round((p - pres[i-1]) / 1000 / V)))
bins = collections.defaultdict(list)
for ph, lat, g in rows: bins[int(ph // 1)].append((lat, g))
print(f"vsync {V:.3f} ms")
print("phase(ms)  frames  median tick->present(ms)  irregular gaps (not 2 vsyncs)")
for b in sorted(bins):
    xs = bins[b]; lats = sorted(x[0] for x in xs); irr = sum(1 for x in xs if x[1] != 2)
    print(f"  {b}-{b+1}     {len(xs):4d}     {lats[len(lats)//2]:6.2f}                 {irr:3d}  ({100*irr/len(xs):.0f}%)")
