"""Fetches a month of anime airing times from AniList into app/art/airing.json, with each show's banner
(or cover) saved under app/art/, so the calendar can be tried with a full month. Keeps shows with at
least --min-popularity AniList members and no adult titles. Dates are local to this machine.

usage: python3 -I tools/fetch-airing.py 2026-11 [--min-popularity 5000]"""
import datetime, json, os, re, sys, time, urllib.request

ART = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "app", "art")
UA = {"User-Agent": "seimio-lab/1.0", "Content-Type": "application/json"}
QUERY = """query ($page: Int, $from: Int, $to: Int) {
  Page(page: $page, perPage: 50) {
    pageInfo { hasNextPage }
    airingSchedules(airingAt_greater: $from, airingAt_lesser: $to, sort: TIME) {
      episode airingAt
      media { id isAdult popularity format title { romaji english } bannerImage coverImage { extraLarge } description(asHtml: false) }
    }
  }
}"""


def gql(variables):
    body = json.dumps({"query": QUERY, "variables": variables}).encode()
    for attempt in range(5):
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


def main():
    month = sys.argv[1]
    min_pop = int(sys.argv[sys.argv.index("--min-popularity") + 1]) if "--min-popularity" in sys.argv else 5000
    y, m = map(int, month.split("-"))
    start = datetime.datetime(y, m, 1)
    end = datetime.datetime(y + (m == 12), m % 12 + 1, 1)
    out, page = [], 1
    while True:
        p = gql({"page": page, "from": int(start.timestamp()) - 1, "to": int(end.timestamp())})
        for s in p["airingSchedules"]:
            md = s["media"]
            if md["isAdult"] or (md["popularity"] or 0) < min_pop: continue
            art = md["bannerImage"] or md["coverImage"]["extraLarge"]
            out.append({"id": f"anilist:{md['id']}", "name": md["title"]["english"] or md["title"]["romaji"], "episode": s["episode"],
                        "date": datetime.datetime.fromtimestamp(s["airingAt"]).strftime("%Y-%m-%d"),
                        "time": datetime.datetime.fromtimestamp(s["airingAt"]).strftime("%H:%M"),
                        "art": save(art, f"al_{md['id']}") if art else "",
                        "description": re.sub(r"<[^>]+>", " ", md["description"] or "").strip()[:260]})
        if not p["pageInfo"]["hasNextPage"]: break
        page += 1
    json.dump(out, open(os.path.join(ART, "airing.json"), "w"), ensure_ascii=False)
    print(f"{len(out)} episodes of {len({e['id'] for e in out})} shows in {month}")


if __name__ == "__main__":
    main()
