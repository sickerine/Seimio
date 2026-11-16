"""Explain dropped frames: which pipeline stage was slow, and what the GPU/raster/main threads did."""
import json, sys, collections, statistics

ev = json.load(open(sys.argv[1]))
names = {(e['pid'], e['tid']): e['args']['name'] for e in ev if e.get('ph') == 'M' and e.get('name') == 'thread_name'}

# Pair async begin/end events per (cat-agnostic) id; PipelineReporter children share the id.
open_ = collections.defaultdict(list)
slices = []
for e in sorted((e for e in ev if e.get('ph') in ('b', 'e') and 'id2' in e), key=lambda e: (e['ts'], 0 if e['ph'] == 'e' else 1)):
    key = (e['pid'], e['id2'].get('local') or e['id2'].get('global'))
    if e['ph'] == 'b':
        open_[key].append(e)
    else:
        st = open_[key]
        for i in range(len(st) - 1, -1, -1):
            if st[i]['name'] == e['name']:
                b = st.pop(i)
                slices.append({'name': b['name'], 'ts': b['ts'], 'dur': e['ts'] - b['ts'], 'args': b.get('args', {}), 'key': key, 'depth': i})
                break

reports = [s for s in slices if s['name'] == 'PipelineReporter' and not s['args'].get('chrome_frame_reporter', {}).get('frame_type')]
by_key = collections.defaultdict(list)
for s in slices:
    if s['name'] != 'PipelineReporter':
        by_key[s['key']].append(s)

def stages(r):
    out = {}
    for s in by_key[r['key']]:
        if r['ts'] <= s['ts'] and s['ts'] + s['dur'] <= r['ts'] + r['dur']:
            out[s['name']] = out.get(s['name'], 0) + s['dur'] / 1000
    return out

state = lambda r: r['args'].get('chrome_frame_reporter', {}).get('state')
dropped = [r for r in reports if state(r) == 'STATE_DROPPED']
presented = [r for r in reports if state(r) in ('STATE_PRESENTED_ALL', 'STATE_PRESENTED_PARTIAL')]
print(f"frames: presented {len(presented)}  dropped {len(dropped)}")
for label, group in (('presented', presented), ('dropped', dropped)):
    if not group: continue
    agg = collections.defaultdict(list)
    for r in group:
        for k, v in stages(r).items(): agg[k].append(v)
    print(f"\n{label} frames, median ms per stage (stages present in >20% of frames):")
    for k, vs in sorted(agg.items(), key=lambda kv: -statistics.median(kv[1])):
        if len(vs) > 0.2 * len(group):
            print(f"   {statistics.median(vs):6.2f}  p90 {sorted(vs)[int(len(vs)*.9)]:6.2f}  n={len(vs):4d}  {k}")
    flags = collections.Counter()
    for r in group:
        a = r['args'].get('chrome_frame_reporter', {})
        for f in ('has_main_animation', 'has_compositor_animation', 'checkerboarded_needs_raster', 'checkerboarded_needs_record', 'has_missing_content', 'affects_smoothness'):
            if a.get(f): flags[f] += 1
    print(f"   flags: {dict(flags)}")

# Thread work during the run
xs = [e for e in ev if e.get('ph') == 'X' and 'dur' in e]
work = collections.Counter(); count = collections.Counter(); mx = collections.Counter()
for e in xs:
    t = names.get((e['pid'], e['tid']), '?').rstrip('0123456789/')
    if e['name'] in ('Display::DrawAndSwap', 'DirectRenderer::DrawFrame', 'SkiaOutputSurfaceImplOnGpu::SwapBuffers', 'SkiaOutputSurfaceImplOnGpu::FinishPaintCurrentFrame',
                     'RasterTask', 'ImageDecodeTask', 'ProxyMain::BeginMainFrame', 'Graphics.Pipeline.DrawAndSwap', 'GpuChannel::ExecuteDeferredRequest',
                     'TileManager::FlushAndIssueSignals', 'LayerTreeHostImpl::PrepareToDraw', 'CommitAndActivate'):
        work[(t, e['name'])] += e['dur'] / 1000; count[(t, e['name'])] += 1; mx[(t, e['name'])] = max(mx[(t, e['name'])], e['dur'] / 1000)
print("\nthread work (total ms / count / max ms):")
for k, v in work.most_common(14):
    print(f"   {v:8.1f}  n={count[k]:5d}  max {mx[k]:6.1f}  {k[0]} :: {k[1]}")

# What the eye sees: gaps between consecutive presented frames.
pr = sorted(presented, key=lambda r: r['ts'] + r['dur'])
gaps = []
for a, b in zip(pr, pr[1:]):
    g = (b['ts'] + b['dur'] - a['ts'] - a['dur']) / 1000
    # only while a compositor animation runs, and not across idle pauses between loops
    if b['args'].get('chrome_frame_reporter', {}).get('has_compositor_animation') and g < 200:
        gaps.append(g)
if gaps:
    g = sorted(gaps)
    anim_s = sum(gaps) / 1000
    print(f"\nanimated {anim_s:.1f}s  late>20ms per s {sum(x > 20 for x in gaps)/anim_s:.2f}  late>30ms per s {sum(x > 30 for x in gaps)/anim_s:.2f}")
    print(f"\npresent gaps: median {g[len(g)//2]:.1f} ms  p95 {g[int(len(g)*.95)]:.1f}  max {g[-1]:.1f}  >25ms {sum(x > 25 for x in gaps)}  >40ms {sum(x > 40 for x in gaps)}")
