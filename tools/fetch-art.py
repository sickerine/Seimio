"""Fetches the lab's data and art into app/art/:
  rows.json    Cinemeta's popular movies and series, with posters, backdrops and title logos
  cw.json      your Continue Watching (from the core probe on the TV), with backdrops and logos
  series.json  episodes, thumbnails and watch state for the shows in Continue Watching
Image URLs often serve WebP whatever their extension, so files are saved under their real format.
Watched episodes come from Stremio's bitfield ("anchorId:anchorLength:base64(zlib(bits))", bits over
the show's episodes sorted by season then episode, shifted so the anchor episode lines up).

usage: python3 -I tools/fetch-art.py <cw.out.json> <library_recent.json>
       (both from the core probe's storage on the TV: /media/developer/temp/core/run*/)"""
import base64, json, os, sys, urllib.request, zlib

UA = {"User-Agent": "seimio-lab/1.0"}
ART = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "art")
os.makedirs(ART, exist_ok=True)


def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30).read()


def save(url, stem):
    """Downloads url to app/art/<stem>.<real extension>; returns the file name, or "" if it failed."""
    done = [f for f in os.listdir(ART) if f.rsplit(".", 1)[0] == stem]
    if done: return done[0]
    try: data = get(url)
    except Exception as e:
        print("  failed", url[:90], e); return ""
    ext = "webp" if data[:4] == b"RIFF" else "png" if data[:4] == b"\x89PNG" else "jpg"
    open(os.path.join(ART, f"{stem}.{ext}"), "wb").write(data)
    return f"{stem}.{ext}"


def meta_of(kind, mid):
    url = f"https://anime-kitsu.strem.fun/meta/{kind}/{mid}.json" if mid.startswith("kitsu:") else f"https://v3-cinemeta.strem.io/meta/{kind}/{mid}.json"
    return json.loads(get(url))["meta"]


def popular_rows():
    rows = []
    for kind, title in (("movie", "Popular movies"), ("series", "Popular series")):
        metas = [m for m in json.loads(get(f"https://v3-cinemeta.strem.io/catalog/{kind}/top.json"))["metas"] if m.get("poster") and m.get("background")][:14]
        items = []
        for m in metas:
            mid = m["id"]
            items.append({"id": mid, "name": m["name"], "year": str(m.get("releaseInfo", "")), "genres": (m.get("genres") or [])[:2],
                          "rating": m.get("imdbRating", ""), "runtime": m.get("runtime", ""), "description": (m.get("description") or "")[:220],
                          "poster": save(f"https://images.metahub.space/poster/medium/{mid}/img", f"p_{mid}"),
                          "backdrop": save(f"https://images.metahub.space/background/medium/{mid}/img", f"b_{mid}"),
                          "logo": save(f"https://images.metahub.space/logo/medium/{mid}/img", f"l_{mid}")})
        rows.append({"title": title, "items": items})
    return rows


def continue_watching(cw_path):
    out = []
    for i in json.load(open(cw_path))[:10]:
        vid, parts, key = i.get("videoId") or "", (i.get("videoId") or "").split(":"), i["id"].replace(":", "_")
        ep = ""
        if i["type"] == "series" and len(parts) == 3: ep = f"E{parts[2]}" if vid.startswith("kitsu:") else f"S{parts[1]} E{parts[2]}"
        if i["id"].startswith("kitsu:"):
            m = meta_of(i["type"], i["id"])
            bg, logo, desc, genres, year = m.get("background"), m.get("logo"), m.get("description", ""), (m.get("genres") or [])[:2], str(m.get("releaseInfo", ""))
        else:
            bg, logo = f"https://images.metahub.space/background/medium/{i['id']}/img", f"https://images.metahub.space/logo/medium/{i['id']}/img"
            desc, genres, year = "", [], ""
        out.append({"id": i["id"], "name": i["name"], "type": i["type"], "episode": ep, "progress": round(i.get("progress") or 0, 1),
                    "backdrop": save(bg, f"cwb_{key}") if bg else "", "logo": save(logo, f"cwl_{key}") if logo else "",
                    "description": (desc or "")[:220], "genres": genres, "year": year})
    return out


def watched_ids(field, video_ids):
    if not field: return set()
    parts = field.split(":")
    bits = zlib.decompress(base64.b64decode(parts[-1]))
    anchor_len, anchor = int(parts[-2]), ":".join(parts[:-2])
    if anchor not in video_ids: return set()
    offset = anchor_len - video_ids.index(anchor) - 1
    return {vid for i, vid in enumerate(video_ids) if 0 <= i + offset < len(bits) * 8 and bits[(i + offset) // 8] >> ((i + offset) % 8) & 1}


def series(ids, library):
    out = {}
    for sid in ids:
        meta = meta_of("series", sid)
        videos = sorted(meta.get("videos", []), key=lambda v: (int(v.get("season") or 0), int(v.get("episode") or v.get("number") or 0)))
        state = library.get(sid, {}).get("state", {})
        seen = watched_ids(state.get("watched"), [v["id"] for v in videos])
        seasons = {}
        for v in videos:
            s, e = int(v.get("season") or 0), int(v.get("episode") or v.get("number") or 0)
            if s == 0: continue                                  # specials
            thumb = save(v["thumbnail"], f"ep_{sid.replace(':', '_')}_{s}_{e}") if v.get("thumbnail") else ""
            progress = round(100 * state.get("timeOffset", 0) / state["duration"], 1) if state.get("video_id") == v["id"] and state.get("duration") else 0
            seasons.setdefault(s, []).append({"id": v["id"], "episode": e, "title": v.get("title") or v.get("name") or "",
                                              "overview": (v.get("overview") or "")[:260], "released": (v.get("released") or v.get("firstAired") or "")[:10],
                                              "runtime": v.get("runtime") or meta.get("runtime") or "", "thumb": thumb,
                                              "watched": v["id"] in seen, "progress": progress})
        out[sid] = {"name": meta["name"], "current": state.get("video_id") or "",
                    "description": (meta.get("description") or "")[:260], "genres": (meta.get("genres") or [])[:2],
                    "year": str(meta.get("releaseInfo") or meta.get("year") or "").rstrip("-–"), "rating": str(meta.get("imdbRating") or ""),
                    "seasons": [{"season": s, "episodes": eps} for s, eps in sorted(seasons.items())]}
        print(f"  {meta['name'][:40]:40s} {len(seasons)} seasons, {len(seen)} watched")
    return out


if __name__ == "__main__":
    cw_path, lib_path = sys.argv[1], sys.argv[2]
    lib = json.load(open(lib_path))
    items = lib["items"] if isinstance(lib, dict) and "items" in lib else lib
    library = {i["_id"]: i for i in (items.values() if isinstance(items, dict) else items)}
    print("popular rows"); json.dump(popular_rows(), open(os.path.join(ART, "rows.json"), "w"), ensure_ascii=False)
    print("continue watching"); cw = continue_watching(cw_path); json.dump(cw, open(os.path.join(ART, "cw.json"), "w"), ensure_ascii=False)
    print("shows"); json.dump(series([i["id"] for i in cw if i["type"] == "series"], library), open(os.path.join(ART, "series.json"), "w"), ensure_ascii=False)
