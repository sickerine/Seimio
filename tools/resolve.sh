#!/bin/bash
# usage: resolve.sh <type> <id> <title substring>  -> prints a TorBox CDN link (one connection per request)
K=TORBOX_KEY; A="stremio-webos-lab/1.0"
U=$(curl -s -A "$A" "https://torrentio.strem.fun/torbox=$K/stream/$1/$2.json" | python3 -c "
import json,sys
for s in json.load(sys.stdin)['streams']:
    if sys.argv[1] in s.get('title',''): print(s['url']); break" "$3")
[ -z "$U" ] && { echo "no stream matching $3" >&2; exit 1; }
L=$(curl -s -A "$A" -o /dev/null -w "%{redirect_url}" "$U")
curl -s -A "$A" -o /dev/null -w "%{redirect_url}" "$L"
