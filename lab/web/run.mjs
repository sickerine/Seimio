// Runs each motion-lab experiment on the TV under a trace and reports frames presented vs dropped.
// usage: node run.mjs [filter]
import http from 'http';

const filter = process.argv[2] || '';
const get = p => new Promise((res, rej) => http.get({ host: '127.0.0.1', port: 9998, path: p }, r => {
  let b = ''; r.on('data', c => (b += c)); r.on('end', () => res(JSON.parse(b)));
}).on('error', rej));
const page = (await get('/json')).find(t => t.type === 'page' && /:8090\/lab/.test(t.url));
if (!page) throw new Error('lab page not open on the TV');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => (ws.onopen = r));
let id = 0; const wait = new Map(); let events = []; let done = null;
ws.onmessage = m => {
  const x = JSON.parse(m.data);
  if (x.id && wait.has(x.id)) { wait.get(x.id)(x); wait.delete(x.id); }
  if (x.method === 'Tracing.dataCollected') events.push(...x.params.value);
  if (x.method === 'Tracing.tracingComplete') done && done();
};
const send = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;

const names = (await ev('window.__names')).filter(n => n.includes(filter));
const rows = [];
for (const name of names) {
  events = [];
  await send('Tracing.start', { categories: 'disabled-by-default-devtools.timeline.frame,cc', options: 'record-as-much-as-possible' });
  const f = await ev(`window.__run(${JSON.stringify(name)}, 6000)`);
  await new Promise(r => { done = r; send('Tracing.end'); });
  const st = { all: 0, partial: 0, dropped: 0 };
  for (const e of events) {
    if (e.name !== 'PipelineReporter' || e.ph !== 'b') continue;
    const a = e.args?.chrome_frame_reporter || {};
    if (a.frame_type) continue;                       // count each frame once (skip forked/backfill)
    if (a.state === 'STATE_PRESENTED_ALL') st.all++;
    else if (a.state === 'STATE_PRESENTED_PARTIAL') st.partial++;
    else if (a.state === 'STATE_DROPPED') st.dropped++;
  }
  const s = f.slice().sort((a, b) => a - b);
  const tot = st.all + st.partial + st.dropped;
  const row = {
    name,
    dropPct: tot ? +(100 * st.dropped / tot).toFixed(1) : null,
    partialPct: tot ? +(100 * st.partial / tot).toFixed(1) : null,
    rafFps: +(f.length / (f.reduce((a, b) => a + b, 0) / 1000)).toFixed(1),
    rafP95: +(s[Math.floor(s.length * 0.95)] || 0).toFixed(1),
  };
  rows.push(row);
  console.log(`${String(row.dropPct).padStart(5)}% dropped  ${String(row.partialPct).padStart(5)}% partial  rAF ${row.rafFps} fps p95 ${row.rafP95} ms  ${name}`);
}
ws.close();
