// Runs one lab experiment under a detailed trace and saves it for analysis.
// usage: node diag.mjs "<experiment name>" out.json [ms]
import http from 'http';
import { writeFileSync } from 'fs';

const [name, out, ms = '6000'] = process.argv.slice(2);
const get = p => new Promise((res, rej) => http.get({ host: '127.0.0.1', port: 9998, path: p }, r => {
  let b = ''; r.on('data', c => (b += c)); r.on('end', () => res(JSON.parse(b)));
}).on('error', rej));
const page = (await get('/json')).find(t => t.type === 'page' && /:8090\/lab/.test(t.url));
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => (ws.onopen = r));
let id = 0; const wait = new Map(); const events = []; let done = null;
ws.onmessage = m => {
  const x = JSON.parse(m.data);
  if (x.id && wait.has(x.id)) { wait.get(x.id)(x); wait.delete(x.id); }
  if (x.method === 'Tracing.dataCollected') events.push(...x.params.value);
  if (x.method === 'Tracing.tracingComplete') done && done();
};
const send = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
await send('Tracing.start', {
  categories: 'disabled-by-default-devtools.timeline.frame,cc,viz,gpu,disabled-by-default-cc.debug.scheduler,devtools.timeline,toplevel',
  options: 'record-as-much-as-possible',
});
await send('Runtime.evaluate', { expression: `window.__noraf = ${process.env.NORAF ? 'true' : 'false'}`, returnByValue: true });
await send('Runtime.evaluate', { expression: `window.__run(${JSON.stringify(name)}, ${ms})`, returnByValue: true, awaitPromise: true });
await new Promise(r => { done = r; send('Tracing.end'); });
writeFileSync(out, JSON.stringify(events));
console.log('events', events.length);
ws.close();
