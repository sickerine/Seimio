"""Survey: can an anime's seasons be grouped by its TVDB show (Fribb's anime-lists, as ARM serves them)?
Runs over AniList's most popular TV/ONA anime and reports what breaks: mapping gaps, split seasons,
sequels in another show or none, season gaps, Kitsu listings, and Torrentio streams for later seasons.
Findings: docs/anime-seasons.md.

usage: python3 -I tools/survey-anime-seasons.py [count, default 300] [first AniList page, default 1]
(works in .lab/anime-survey: downloads Fribb's anime-list-full.json there once, and caches AniList pages)"""
import collections, concurrent.futures as cf, json, os, sys, time, urllib.request

HERE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".lab", "anime-survey")
os.makedirs(HERE, exist_ok=True)
UA = {"User-Agent": "seimio-research", "Content-Type": "application/json", "Accept": "application/json"}
N = int(sys.argv[1]) if len(sys.argv) > 1 else 300
START = int(sys.argv[2]) if len(sys.argv) > 2 else 1


def get(url, body=None, tries=3):
    for t in range(tries):
        try:
            return json.loads(urllib.request.urlopen(urllib.request.Request(url, body, UA), timeout=30).read())
        except Exception as e:
            if t == tries - 1: return {"error": str(e)}
            time.sleep(3 * (t + 1))


Q = """query($page:Int){ Page(page:$page, perPage:50){ media(type:ANIME, sort:POPULARITY_DESC, format_in:[TV, TV_SHORT, ONA]){
  id format status episodes title{romaji english} startDate{year month}
  relations{ edges{ relationType node{ id type format status episodes startDate{year month} title{romaji} } } } } } }"""


def anilist():
    path = os.path.join(HERE, f"anilist-{START}.json")
    if os.path.exists(path): return json.load(open(path))
    out = []
    for page in range(START, START + N // 50):
        d = get("https://graphql.anilist.co", json.dumps({"query": Q, "variables": {"page": page}}).encode())
        out += d["data"]["Page"]["media"]
        time.sleep(2.5)
    json.dump(out, open(path, "w"))
    return out


def main():
    shows = anilist()
    lists = os.path.join(HERE, "anime-list-full.json")
    if not os.path.exists(lists):
        urllib.request.urlretrieve("https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json", lists)
    fribb = json.load(open(lists))
    by_anilist = {x["anilist_id"]: x for x in fribb if x.get("anilist_id")}
    by_tvdb = collections.defaultdict(list)
    for x in fribb:
        if x.get("tvdb_id"): by_tvdb[x["tvdb_id"]].append(x)
    issues = collections.defaultdict(list)
    groups = {}
    name = lambda m: (m["title"]["english"] or m["title"]["romaji"])[:48]
    for s in shows:
        m = by_anilist.get(s["id"])
        if not m: issues["no mapping at all"].append(name(s)); continue
        if not m.get("kitsu_id"): issues["no Kitsu id (can't play by Kitsu)"].append(name(s))
        if not m.get("tvdb_id"): issues["no TVDB show (can't group)"].append(f"{name(s)} [{s['status']}]"); continue
        tv = m["tvdb_id"]; groups[tv] = name(s) if tv not in groups else groups[tv]
        # sequels and prequels that are shows: same TVDB show, and in order?
        for e in s["relations"]["edges"]:
            n = e["node"]
            if e["relationType"] not in ("SEQUEL", "PREQUEL") or n["type"] != "ANIME" or n["format"] not in ("TV", "TV_SHORT", "ONA"): continue
            nm = by_anilist.get(n["id"])
            if not nm or not nm.get("tvdb_id"):
                issues["a sequel/prequel has no TVDB show"].append(f"{name(s)} -> {n['title']['romaji'][:40]} [{n['status']}]")
            elif nm["tvdb_id"] != tv:
                issues["a sequel/prequel is another TVDB show"].append(f"{name(s)} -> {n['title']['romaji'][:40]}")
            else:
                a, b = m.get("season", {}).get("tvdb"), nm.get("season", {}).get("tvdb")
                if isinstance(a, int) and isinstance(b, int) and a > 0 and b > 0:
                    if (e["relationType"] == "SEQUEL" and b < a) or (e["relationType"] == "PREQUEL" and b > a):
                        issues["sequel order disagrees with TVDB seasons"].append(f"{name(s)} s{a} {e['relationType'].lower()} s{b}")
    # each group: its seasons
    season_kinds = collections.Counter()
    plan = []                                           # (tvdb, season, kitsu) to check on the Kitsu addon
    for tv, label in groups.items():
        entries = by_tvdb[tv]
        seasons = collections.defaultdict(list)
        for x in entries:
            sv = x.get("season", {}).get("tvdb")
            season_kinds[type(sv).__name__ + ("" if isinstance(sv, int) else f":{sv}")] += 1
            if isinstance(sv, int) and sv >= 1: seasons[sv].append(x)
        nums = sorted(seasons)
        if nums and nums != list(range(1, nums[-1] + 1)): issues["gaps in season numbers"].append(f"{label}: {nums}")
        for sv, xs in seasons.items():
            if len(xs) > 1:
                offs = sorted(x.get("episode_offset", {}).get("tvdb", 0) for x in xs)
                kind = "split season, offsets given" if len(set(offs)) == len(offs) else "split season, offsets missing or equal"
                issues[kind].append(f"{label} s{sv}: {len(xs)} entries, offsets {offs}")
        for sv, xs in seasons.items():
            for x in xs:
                if x.get("kitsu_id"): plan.append((tv, sv, x["kitsu_id"], x.get("anilist_id"), label))
    # Kitsu addon: does each season's entry list its episodes as one season?
    eps = {s["id"]: s["episodes"] for s in shows}
    multi = {tv for tv, _, _, _, _ in plan if sum(1 for p in plan if p[0] == tv) > 1}
    plan = [p for p in plan if p[0] in multi]
    def meta(p):
        d = get(f"https://anime-kitsu.strem.fun/meta/series/kitsu:{p[2]}.json")
        return p, d
    kstats = collections.Counter()
    with cf.ThreadPoolExecutor(4) as ex:
        for p, d in ex.map(meta, plan[:400]):
            m = d.get("meta") if isinstance(d, dict) else None
            if not m: kstats["meta missing"] += 1; issues["Kitsu addon has no meta"].append(f"{p[4]} s{p[1]} kitsu:{p[2]}"); continue
            v = m.get("videos") or []
            kseasons = sorted({x.get("season") for x in v})
            kstats["metas"] += 1
            if not v: issues["Kitsu meta lists no episodes"].append(f"{p[4]} s{p[1]} kitsu:{p[2]}")
            if len(kseasons) > 1: issues["one Kitsu entry spans several seasons"].append(f"{p[4]} s{p[1]} kitsu:{p[2]} seasons {kseasons}")
            al = eps.get(p[3])
            if al and v and abs(len(v) - al) > 1: issues["Kitsu episode count differs from AniList"].append(f"{p[4]} s{p[1]}: kitsu {len(v)} anilist {al}")
    # Torrentio: later seasons' first episode by Kitsu id
    later = [p for p in plan if p[1] >= 2][:60]
    def streams(p):
        d = get(f"https://torrentio.strem.fun/stream/series/kitsu:{p[2]}:1.json")
        return p, len(d.get("streams", [])) if isinstance(d, dict) else -1
    tstats = collections.Counter()
    with cf.ThreadPoolExecutor(3) as ex:
        for p, n in ex.map(streams, later):
            tstats["checked"] += 1
            if n <= 0: issues["Torrentio has nothing for a later season's Kitsu id"].append(f"{p[4]} s{p[1]} kitsu:{p[2]}")
    print(f"shows {len(shows)}, TVDB shows {len(groups)}, with 2+ seasons {len(multi)}, Kitsu metas checked {kstats['metas']}, Torrentio checked {tstats['checked']}")
    print("season values:", dict(season_kinds))
    for k, v in sorted(issues.items(), key=lambda kv: -len(kv[1])):
        print(f"\n{k}: {len(v)}")
        for line in v[:14]: print("   ", line)
    json.dump(issues, open(os.path.join(HERE, f"issues-{START}.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
