"""Builds lab/design art/series.json: real episodes, thumbnails and your watch state for the design lab.
usage: python3 -I design-series.py <library_recent.json> <art dir> <series ids...>
Watched episodes come from Stremio's bitfield ("anchorId:anchorLength:base64(zlib(bits))", bits over the
show's episodes sorted by season then episode, shifted so the anchor episode lines up)."""
import base64, json, os, sys, urllib.request, zlib

UA = {"User-Agent": "stremio-webos-lab/1.0"}
lib_path, art, ids = sys.argv[1], sys.argv[2], sys.argv[3:]

def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30).read()

def watched_ids(field, video_ids):
    if not field: return set()
    parts = field.split(":")
    bits = zlib.decompress(base64.b64decode(parts[-1]))
    anchor_len, anchor = int(parts[-2]), ":".join(parts[:-2])
    if anchor not in video_ids: return set()
    offset = anchor_len - video_ids.index(anchor) - 1
    out = set()
    for i, vid in enumerate(video_ids):
        j = i + offset
        if 0 <= j < len(bits) * 8 and bits[j // 8] >> (j % 8) & 1: out.add(vid)
    return out

lib = json.load(open(lib_path))
items = lib["items"] if isinstance(lib, dict) and "items" in lib else lib
items = items.values() if isinstance(items, dict) else items
library = {i["_id"]: i for i in items}

out = {}
for sid in ids:
    url = f"https://anime-kitsu.strem.fun/meta/series/{sid}.json" if sid.startswith("kitsu:") else f"https://v3-cinemeta.strem.io/meta/series/{sid}.json"
    meta = json.loads(get(url))["meta"]
    videos = sorted(meta.get("videos", []), key=lambda v: (int(v.get("season") or 0), int(v.get("episode") or v.get("number") or 0)))
    state = library.get(sid, {}).get("state", {})
    seen = watched_ids(state.get("watched"), [v["id"] for v in videos])
    seasons = {}
    for v in videos:
        s = int(v.get("season") or 0)
        if s == 0: continue                                  # specials
        key = sid.replace(":", "_")
        thumb = ""
        if v.get("thumbnail"):
            data = None
            done = [f for f in os.listdir(art) if f.startswith(f"ep_{key}_{s}_{v.get('episode') or v.get('number')}.")]
            if done: thumb = done[0]   # already downloaded
            try: data = None if done else get(v["thumbnail"])
            except Exception as e: print("  thumbnail failed", v["id"], e)
            if data:
                ext = "webp" if data[:4] == b"RIFF" else ("png" if data[:4] == b"\x89PNG" else "jpg")
                thumb = f"ep_{key}_{s}_{v.get('episode') or v.get('number')}.{ext}"
                open(os.path.join(art, thumb), "wb").write(data)
        progress = 0
        if state.get("video_id") == v["id"] and state.get("duration"):
            progress = round(100 * state.get("timeOffset", 0) / state["duration"], 1)
        seasons.setdefault(s, []).append({
            "id": v["id"], "episode": int(v.get("episode") or v.get("number") or 0),
            "title": v.get("title") or v.get("name") or "", "overview": (v.get("overview") or "")[:260],
            "released": (v.get("released") or v.get("firstAired") or "")[:10], "runtime": v.get("runtime") or meta.get("runtime") or "",
            "thumb": thumb, "watched": v["id"] in seen, "progress": progress,
        })
    year = str(meta.get("releaseInfo") or meta.get("year") or "").rstrip("-\u2013")
    out[sid] = {"name": meta["name"], "current": state.get("video_id") or "",
                "description": (meta.get("description") or "")[:260], "genres": (meta.get("genres") or [])[:2],
                "year": year, "rating": str(meta.get("imdbRating") or ""), "seasons": [{"season": s, "episodes": eps} for s, eps in sorted(seasons.items())]}
    n = sum(len(x["episodes"]) for x in out[sid]["seasons"])
    print(f"{meta['name'][:40]:40s} {len(seasons)} seasons, {n} episodes, {len(seen)} watched, current {out[sid]['current']}")
json.dump(out, open(os.path.join(art, "series.json"), "w"), ensure_ascii=False)
