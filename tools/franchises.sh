#!/bin/bash
# Puts franchises together on the Mac with the app's own loader (Catalog.loadFranchise, live network, an
# empty account) and checks what a page promises: a title it lists under Related opens as a page of its
# own, not as this show again; no title is both an entry of the show and related to it; and a numbered
# season is a season (one made of a single short entry that came after the last is named, to look at).
# With no ids it takes AniList's most popular anime. Prints each show's tabs and what it found; exits 1
# on a broken promise, and on a show or a related title that could not be put together.
# (The Mac's Qt can't make a TLS connection to arm.haglund.dev, where a franchise starts, so a relay runs
# beside it for the length of the run: tools/arm-relay.py.)
# usage: tools/franchises.sh [id...]     ids as the app has them: anilist:101280, kitsu:49235
REPO=$(cd "$(dirname "$0")/.." && pwd); OUT="$REPO/.lab/franchises"; mkdir -p "$OUT"
PORT=8099
python3 -I "$REPO/tools/arm-relay.py" "$PORT" &
relay=$!; trap 'kill $relay 2>/dev/null; wait $relay 2>/dev/null' EXIT; sleep 1
run() {       # ids, comma separated: one line of JSON a franchise
  rm -rf "$OUT/account"; mkdir -p "$OUT/account"
  SEIMIO_ACCOUNT="$OUT/account" SEIMIO_VIA="arm.haglund.dev=http://127.0.0.1:$PORT" perl -e 'alarm shift; exec @ARGV' 1800 \
    /opt/homebrew/opt/qt@5/bin/qml -I "$REPO/tools/preview/imports" -I "$REPO/app" "$REPO/tools/preview/franchise.qml" -- "$1" 2>&1 | sed -n 's/^qml: FRANCHISE //p'
}
ids=$(IFS=,; echo "$*")
if [ -z "$ids" ]; then
  ids=$(curl -s -A "seimio/0.1" -H "Content-Type: application/json" -d '{"query":"query { Page(perPage: 40) { media(type: ANIME, format: TV, sort: POPULARITY_DESC) { id } } }"}' https://graphql.anilist.co \
        | python3 -I -c "import json,sys; print(','.join('anilist:%d' % m['id'] for m in json.load(sys.stdin)['data']['Page']['media']))")
fi
run "$ids" > "$OUT/shows.jsonl"
# every title a show lists as related, opened in its turn
related=$(python3 -I -c "
import json,sys
seen=set()
for line in open(sys.argv[1]):
    for r in json.loads(line).get('related', []): seen.add(r['id'])
print(','.join(sorted(seen)))" "$OUT/shows.jsonl")
: > "$OUT/related.jsonl"; [ -n "$related" ] && run "$related" > "$OUT/related.jsonl"
python3 -I - "$OUT/shows.jsonl" "$OUT/related.jsonl" "$ids" <<'PY'
import json, sys
shows = [json.loads(l) for l in open(sys.argv[1])]
asked = sys.argv[3].split(",") if len(sys.argv) > 3 and sys.argv[3] else []
missing = [i for i in asked if i not in set(f["asked"] for f in shows)]
opened = {f["asked"]: f for f in (json.loads(l) for l in open(sys.argv[2]))}
bad = 0
def tab(t): return ("Season %d" % t["season"]) if t["season"] else t["label"]
# the entries a show's own tabs are made of (its related shows are entries too, for their logo and backdrop)
def own(f): return set(f["entries"][i]["id"] for t in f["tabs"] if t["kind"] != "related" for i in t["entries"])
def where(f, id): return [tab(t) for t in f["tabs"] if t["kind"] != "related" and any(f["entries"][i]["id"] == id for i in t["entries"])]
for f in shows:
    if "failed" in f: bad += 1; print("%-18s BROKEN: could not be put together: %s" % (f["asked"], f["failed"])); continue
    mine = own(f)
    print("%-18s %s" % (f["asked"], f["name"]))
    for t in f["tabs"]:
        if t["kind"] != "related": print("    %-10s %3d  %s" % (tab(t), t["episodes"], "; ".join(f["entries"][i]["title"][:44] for i in t["entries"])))
    for r in f["related"]:
        o = opened.get(r["id"])
        if r["id"] in mine: bad += 1; print("    BROKEN: %s is listed as related and is on %s too" % (r["title"], ", ".join(where(f, r["id"]))))
        elif o and "failed" not in o and own(o) & mine:
            bad += 1; print("    BROKEN: %s (%s) is listed as related; opened, it is this show again, on %s" % (r["title"], r["id"], ", ".join(where(o, r["id"])) or "?"))
        elif not o or "failed" in o: bad += 1; print("    BROKEN: %s (%s) is listed as related and could not be opened: %s" % (r["title"], r["id"], (o or {}).get("failed", "no answer")))
        else: print("    related    %s" % r["title"][:50])
    # a special is short: an entry there with more episodes than a season is a show of its own (Franchise's
    # `ownShow`: MyGO's page had the 196 one-minute web shorts of "Member no Nichijou" as its specials)
    for t in f["tabs"]:
        if t["kind"] == "specials":
            for i, n in zip(t["entries"], t.get("counts", [])):
                if n > 13: bad += 1; print("    BROKEN: %s is among the specials with %d episodes: a show of its own" % (f["entries"][i]["title"], n))
    numbered = [t for t in f["tabs"] if t["season"] > 0]
    if len(numbered) > 1 and len(numbered[-1]["entries"]) == 1 and numbered[-1]["episodes"] <= 3:
        print("    look: %s is one entry of %d episode(s)" % (tab(numbered[-1]), numbered[-1]["episodes"]))
for i in missing: bad += 1; print("%-18s BROKEN: no answer (the run ended before it)" % i)
print("%d shows, %d broken promise(s)" % (len(shows), bad))
sys.exit(1 if bad else 0)
PY
