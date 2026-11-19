// LG network remote (the SSAP API phone remotes use). Pairs once (accept the prompt on the TV), then sends
// remote buttons through the TV's real input path.
// usage: node tvremote.mjs pair | node tvremote.mjs press RIGHT 30 300   (button, count, ms between) | node tvremote.mjs type "some text" | node tvremote.mjs enter
// A long OK is `press ENTER 16 40`: the app takes presses under 90 ms apart as one hold (Remote.qml), as LG's own remote sends them.
import { readFileSync, writeFileSync } from "fs";
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"; // the TV's certificate is self-signed
const TV = process.env.TV_HOST || "192.168.1.37";
const KEY_FILE = process.env.TV_KEY_FILE || new URL("./.tv-client-key", import.meta.url).pathname;
const [cmd, button = "RIGHT", count = "1", gap = "300"] = process.argv.slice(2);
const key = (() => { try { return readFileSync(KEY_FILE, "utf8").trim(); } catch { return undefined; } })();

const ws = new WebSocket(`wss://${TV}:3001`);
let id = 0; const waiting = new Map();
const send = (type, uri, payload) => new Promise(r => { const i = `m${++id}`; waiting.set(i, r); ws.send(JSON.stringify({ id: i, type, uri, payload })); });
ws.onmessage = m => {
  const x = JSON.parse(m.data);
  if (x.type === "registered") { if (x.payload["client-key"] !== key) writeFileSync(KEY_FILE, x.payload["client-key"]); waiting.get(x.id)?.(x); }
  // register first answers "prompt shown"; wait for "registered" (or an error) instead
  else if (x.type === "error" || (x.type === "response" && !x.payload?.pairingType)) waiting.get(x.id)?.(x);
};
await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail; });
const manifest = { manifestVersion: 1, appVersion: "1.0", signed: { appId: "lab.tvremote", vendorId: "lab", localizedAppNames: { "": "Lab remote" }, permissions: ["CONTROL_INPUT_JOYSTICK", "CONTROL_MOUSE_AND_KEYBOARD"], created: "20261116", serial: "lab" }, permissions: ["CONTROL_INPUT_JOYSTICK", "CONTROL_MOUSE_AND_KEYBOARD", "READ_INSTALLED_APPS"], signatures: [{ signatureVersion: 1, signature: "lab" }] };
console.log(key ? "registering with saved key" : "accept the prompt on the TV");
const reg = await send("register", undefined, { pairingType: "PROMPT", "client-key": key, manifest });
if (reg.type === "error") { console.log("register failed:", reg.error); process.exit(1); }
console.log("paired");
if (cmd === "press") {
  const sock = await send("request", "ssap://com.webos.service.networkinput/getPointerInputSocket");
  const input = new WebSocket(sock.payload.socketPath);
  await new Promise(ok => (input.onopen = ok));
  for (let i = 0; i < Number(count); i++) {
    input.send(`type:button\nname:${button}\n\n`);
    await new Promise(r => setTimeout(r, Number(gap)));
  }
  input.close();
  console.log(`sent ${count} x ${button}`);
}
// text into whatever field the TV's keyboard is up for (`button` is the text here)
if (cmd === "type") {
  const r = await send("request", "ssap://com.webos.service.ime/insertText", { text: button, replace: 0 });
  console.log(r.type === "error" ? "type failed: " + r.error : `typed ${button}`);
}
// Enter on the TV's keyboard, as its own Enter key sends it
if (cmd === "enter") {
  const r = await send("request", "ssap://com.webos.service.ime/sendEnterKey", {});
  console.log(r.type === "error" ? "enter failed: " + r.error : "sent enter");
}
ws.close();
