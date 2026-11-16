// Fetches Torrentio's streams (through TorBox) for the next episode of each Continue Watching title and
// writes them, classified, to app/art/streams.json for the stream picker mock. The classification is the
// patched Stremio app's (stremio-webos: service/overlay/stream-filters.js and the badge code in
// service/index.html), so the mock shows what that app shows. It moves to C++ once the design is agreed.
//
// usage: node tools/fetch-streams.mjs [path to stremio-webos, default ../stremio-webos]
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const REPO = path.dirname(path.dirname(new URL(import.meta.url).pathname));
const ART = path.join(REPO, "app", "art");
const F = createRequire(import.meta.url)(path.resolve(process.argv[2] || path.join(REPO, "..", "stremio-webos"), "service/overlay/stream-filters.js"));
const TORBOX = "TORBOX_KEY";
const UA = { "User-Agent": "seimio-lab/1.0" };

// ---- from the patched app's badges (service/index.html) ----
const RES = [["4K", /(?:^|[^a-z0-9])(?:2160p|4k|uhd)(?:[^a-z0-9]|$)/i], ["1080p", /(?:^|[^a-z0-9])1080p(?:[^a-z0-9]|$)/i],
             ["720p", /(?:^|[^a-z0-9])720p(?:[^a-z0-9]|$)/i], ["480p", /(?:^|[^a-z0-9])480p(?:[^a-z0-9]|$)/i]];
const pickRes = t => (RES.find(([, re]) => re.test(t)) || [null])[0];
function version(t) {
    const n = /\b(?:s\d{1,2}e\d{1,4}|e\d{1,4}|\d{1,4})v(\d{1,2})\b/i.exec(t) || /(?:^|[^a-z0-9])v(\d{1,2})(?:[^a-z0-9]|$)/i.exec(t);
    if (n && +n[1] >= 2) return "V" + +n[1];
    const r = /(?:^|[^a-z0-9])repack(\d*)(?:[^a-z0-9]|$)/i.exec(t);
    return r ? "REPACK" + (r[1] || "") : "";
}
// ---- added for the mock: which HDR, which audio, and why a release won't play ----
function hdr(t) {
    if (/(?:^|[^a-z0-9])(?:dv|dovi|dolby[ ._-]?vision)(?:[^a-z0-9]|$)/i.test(t)) return "DV";
    if (/hdr10\+|hdr10plus/i.test(t)) return "HDR10+";
    if (/(?:^|[^a-z0-9])hdr(?:10)?(?:[^a-z0-9]|$)/i.test(t)) return "HDR";
    return "";
}
const AUDIO = [["TrueHD", /true-?hd/i], ["DTS-HD", /dts[ ._-]?hd|dts[ ._-]?ma/i], ["DTS:X", /dts[ ._:-]?x(?![a-z0-9])/i], ["DTS", /(?:^|[^a-z0-9])dts/i],
               ["DD+", /(?:^|[^a-z0-9])(?:ddpa?|dd\+|e[ ._-]?ac[ ._-]?3|eac3)/i], ["DD", /(?:^|[^a-z0-9])(?:dd|ac[ ._-]?3)(?=[^a-z]|$)/i],
               ["FLAC", /flac/i], ["Opus", /(?:^|[^a-z0-9])opus(?:[^a-z0-9]|$)/i], ["AAC", /aac/i], ["PCM", /(?:^|[^a-z0-9])l?pcm/i]];
const audio = t => AUDIO.filter(([, re]) => re.test(t)).map(([n]) => n).slice(0, 2);

function classify(s, anime) {
    const blob = F.text(s);
    const lines = (s.title || "").split("\n");
    const stats = lines.find(l => l.includes("👤")) || "";
    const langs = lines.slice(lines.indexOf(stats) + 1).join(" ").split("/").map(x => x.trim())
        .filter(x => x && !/\p{Regional_Indicator}/u.test(x));
    const name = (s.name || "").split("\n");
    const a = audio(blob);
    // the patched app's rules, plus Opus: LG's native player rejects it, and the failure jammed the TV's audio
    const opusOnly = a.length > 0 && a.every(x => x === "Opus");
    const support = opusOnly ? "unsupported" : F.support(blob);
    return {
        release: lines[0],
        file: lines.length > 2 && !lines[1].includes("👤") ? lines[1].split("/").pop() : "",
        res: pickRes(name.slice(1).join(" ")) || pickRes(blob) || "",
        hdr: hdr(name.slice(1).join(" ") + " " + blob),
        bd: F.isBD(blob),
        seasonal: anime && F.isSeasonal(blob),
        version: version(blob),
        audio: a,
        support,
        // what won't play here, named
        why: support !== "unsupported" ? "" : opusOnly ? "Opus" : F.videoSupport(blob) === "unsupported" ? "10-bit H.264" : a.find(x => /TrueHD|DTS/.test(x)) || "Audio",
        seeders: +((stats.match(/👤\s*(\d+)/) || [])[1] || 0),
        size: (stats.match(/💾\s*([\d.]+\s*[KMGT]B)/) || [])[1] || "",
        source: (stats.match(/⚙️\s*(.+)$/) || [])[1] || "",
        langs,
        cached: name[0].startsWith("[TB+]"),
        url: s.url,
    };
}

function videoId(i) {
    if (i.type === "movie") return i.id;
    const m = /(?:S(\d+) )?E(\d+)/.exec(i.episode || "");
    if (!m) return null;
    return i.id.startsWith("kitsu:") ? `${i.id}:${m[2]}` : `${i.id}:${m[1] || 1}:${m[2]}`;
}

const out = {};
for (const i of JSON.parse(fs.readFileSync(path.join(ART, "cw.json"), "utf8"))) {
    const vid = videoId(i);
    if (!vid) continue;
    const r = await fetch(`https://torrentio.strem.fun/torbox=${TORBOX}/stream/${i.type}/${vid}.json`, { headers: UA });
    const streams = r.ok ? (await r.json()).streams || [] : [];
    const anime = i.id.startsWith("kitsu:");
    out[i.id] = { videoId: vid, anime, streams: streams.map(s => classify(s, anime)) };
    console.log(`${i.name.slice(0, 40).padEnd(40)} ${vid.padEnd(22)} ${streams.length} streams`);
}
fs.writeFileSync(path.join(ART, "streams.json"), JSON.stringify(out));
