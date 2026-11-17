"""Fetches one anime season from AniList into app/art/season.json, the way AniChart lists it: every
show starting that season or carrying over, with its next episode's air time, studio, format, genres,
score and popularity, and its cover and art saved under app/art/: the full-screen background is the
fanart Stremio's Kitsu addon lists (1920x1080; Kitsu ids from ARM, Fribb's anime-lists), with AniList's
banner (a 1900x400 strip) only when there's none. No adult titles; leftovers from
earlier seasons are kept when they're still airing (AniChart's "leftovers").

usage: /opt/homebrew/bin/python3 -I tools/fetch-season.py FALL 2026 [--min-popularity 3000]
(the system Python's LibreSSL can't reach fanart.tv)"""
import datetime, json, os, re, sys, time, urllib.request

ART = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "art")
UA = {"User-Agent": "seimio-lab/1.0", "Content-Type": "application/json"}
FIELDS = """id isAdult popularity averageScore format episodes duration season seasonYear status source
  title { romaji english native } bannerImage coverImage { extraLarge color }
  description(asHtml: false) genres studios(isMain: true) { nodes { name } }
  startDate { year month day } nextAiringEpisode { episode airingAt }"""
SEASON = "query ($page: Int, $season: MediaSeason, $year: Int) { Page(page: $page, perPage: 50) { pageInfo { hasNextPage } media(season: $season, seasonYear: $year, type: ANIME, sort: POPULARITY_DESC) { %s } } }" % FIELDS
LEFTOVER = "query ($page: Int) { Page(page: $page, perPage: 50) { pageInfo { hasNextPage } media(status: RELEASING, type: ANIME, sort: POPULARITY_DESC) { %s } } }" % FIELDS


def gql(query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    for attempt in range(6):
        try:
            return json.loads(urllib.request.urlopen(urllib.request.Request("https://graphql.anilist.co", body, UA), timeout=30).read())["data"]["Page"]
        except urllib.error.HTTPError as e:
            if e.code != 429: raise
            time.sleep(int(e.headers.get("Retry-After", "30")) + 1)      # AniList allows about 30 requests a minute
    raise SystemExit("AniList kept rate limiting")


def save(url, stem):
    done = [f for f in os.listdir(ART) if f.rsplit(".", 1)[0] == stem]
    if done: return done[0]
    data = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA["User-Agent"]}), timeout=30).read()
    ext = "webp" if data[:4] == b"RIFF" else "png" if data[:4] == b"\x89PNG" else "jpg"
    open(os.path.join(ART, f"{stem}.{ext}"), "wb").write(data)
    return f"{stem}.{ext}"


def pages(query, variables, min_pop):
    page = 1
    while True:
        p = gql(query, dict(variables, page=page))
        for md in p["media"]:
            if md["isAdult"]: continue
            if (md["popularity"] or 0) < min_pop: return
            yield md
        if not p["pageInfo"]["hasNextPage"]: return
        page += 1


def backgrounds(anilist_ids):
    """anilist id -> the Kitsu addon's background url, for those that have one"""
    ids = list(anilist_ids)
    out = {}
    for i in range(0, len(ids), 100):
        body = json.dumps([{"anilist": a} for a in ids[i:i + 100]]).encode()
        rows = json.loads(urllib.request.urlopen(urllib.request.Request("https://arm.haglund.dev/api/v2/ids", body, UA), timeout=30).read())
        for row in rows:
            if not row or not row.get("kitsu"): continue
            try:
                meta = json.loads(urllib.request.urlopen(urllib.request.Request(f"https://anime-kitsu.strem.fun/meta/series/kitsu:{row['kitsu']}.json", headers={"User-Agent": UA["User-Agent"]}), timeout=30).read())["meta"]
            except Exception:
                continue
            if meta.get("background"): out[row["anilist"]] = meta["background"]
    return out


def main():
    season, year = sys.argv[1].upper(), int(sys.argv[2])
    min_pop = int(sys.argv[sys.argv.index("--min-popularity") + 1]) if "--min-popularity" in sys.argv else 3000
    out, seen = [], set()
    for leftover, md in [(False, m) for m in pages(SEASON, {"season": season, "year": year}, min_pop)] + \
                        [(True, m) for m in pages(LEFTOVER, {}, min_pop * 3)]:
        if md["id"] in seen or (leftover and md["format"] not in ("TV", "TV_SHORT", "ONA")): continue
        seen.add(md["id"])
        nxt = md["nextAiringEpisode"]
        out.append({
            "id": f"anilist:{md['id']}", "name": md["title"]["english"] or md["title"]["romaji"], "romaji": md["title"]["romaji"],
            "format": md["format"] or "", "episodes": md["episodes"] or 0, "duration": md["duration"] or 0,
            "status": md["status"] or "", "source": (md["source"] or "").replace("_", " ").title(),
            "studio": ", ".join(n["name"] for n in md["studios"]["nodes"][:2]), "genres": md["genres"][:4],
            "score": md["averageScore"] or 0, "popularity": md["popularity"] or 0, "leftover": leftover,
            "start": "%04d-%02d-%02d" % (md["startDate"]["year"] or 0, md["startDate"]["month"] or 0, md["startDate"]["day"] or 0),
            "next": {"episode": nxt["episode"], "at": nxt["airingAt"]} if nxt else None,
            "color": md["coverImage"]["color"] or "",
            "cover": save(md["coverImage"]["extraLarge"], f"ac_{md['id']}") if md["coverImage"]["extraLarge"] else "",
            "banner": save(md["bannerImage"], f"al_{md['id']}") if md["bannerImage"] else "",
            "description": re.sub(r"\s+", " ", re.sub(r"<[^>]+>|\(Source:[^)]*\)", " ", md["description"] or "")).strip()[:320],
        })
    art = backgrounds(int(s["id"].split(":")[1]) for s in out)
    for s in out:
        url = art.get(int(s["id"].split(":")[1]))
        if url:
            try: s["background"] = save(url, f"ab_{s['id'].split(':')[1]}")
            except Exception: pass
    json.dump({"season": season, "year": year, "fetched": int(time.time()), "shows": out},
              open(os.path.join(ART, "season.json"), "w"), ensure_ascii=False, indent=0)
    print(f"{len(out)} shows ({sum(s['leftover'] for s in out)} leftovers)")


main()
