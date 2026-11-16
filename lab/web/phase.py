"""Phase of Chrome's BeginFrame timer against the screen's real vsync grid (from presentation times)."""
import json, sys, statistics
ev = json.load(open(sys.argv[1]))
pres = sorted(e['ts'] + e.get('dur', 0) for e in ev if e['name'] == 'SwapEndToPresentationCompositorFrame' and e.get('ph') == 'e') or None
if not pres:
    # async end events carry ts of the end directly
    pres = sorted(e['ts'] for e in ev if e['name'] == 'SwapEndToPresentationCompositorFrame' and e.get('ph') == 'e')
pres = sorted(set(pres))
gaps = [(b - a) / 1000 for a, b in zip(pres, pres[1:]) if b - a < 100000]
n = [round(g / 8.3333) for g in gaps]
period = sum(gaps) / sum(n)
print(f"presentations {len(pres)}  vsync period {period:.4f} ms ({1000/period:.3f} Hz)")
print("gap multiples of vsync:", {k: n.count(k) for k in sorted(set(n))})
ticks = sorted(e['args']['frame_time'] for e in ev if e['name'] == 'DelayBasedBeginFrameSource::OnTimerTick')
tg = [(b - a) / 1000 for a, b in zip(ticks, ticks[1:])]
print(f"timer interval {statistics.mean(tg):.4f} ms ({1000/statistics.mean(tg):.3f} Hz)  drift vs 2 vsyncs: {(statistics.mean(tg) - 2*period)*1000:.1f} us per frame")
# phase of each tick against the vsync grid anchored at the first presentation
t0 = pres[0]
ph = [(((t - t0) / 1000) % period) for t in ticks]
step = max(1, len(ph) // 12)
print("tick phase in vsync (ms), sampled:", ' '.join(f"{p:.2f}" for p in ph[::step]))
