#!/bin/bash
# Packages app/ (with the built plugin and the lab art), installs it on the TV and launches it, then
# prints the load result from the lab server. Needs ares-cli on Node 20 and the TV set up as device "tv".
# usage: tools/deploy.sh [seconds to wait]
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
export PATH=~/.nvm/versions/node/v20.20.0/bin:$PATH
mkdir -p app/native .lab/ipk .lab/reports
cp native/out/libseimionative.so native/out/libseimiodata.so native/out/libass.so.9 native/out/qmldir app/native/
[ -f app/art/rows.json ] || { echo "no lab art: run tools/fetch-art.py first"; exit 1; }
id=$(python3 -c "import json;print(json.load(open('app/appinfo.json'))['id'])")
ver=$(python3 -c "import json;print(json.load(open('app/appinfo.json'))['version'])")
# a fresh build number each time, or ares-install keeps the old files
build=$(date +%s); next="${ver%.*}.$((build % 100000))"
tmp=$(mktemp -d); rsync -a --exclude .DS_Store app/ "$tmp/app/"
python3 - "$tmp/app/appinfo.json" "$next" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["version"] = sys.argv[2]; json.dump(d, open(p, "w"), indent=2)
PY
ares-package "$tmp/app" -o .lab/ipk >/dev/null || exit 1
ares-launch -d tv --close "$id" >/dev/null 2>&1
ares-install -d tv ".lab/ipk/${id}_${next}_all.ipk" >/dev/null || exit 1
rm -rf "$tmp"
mark=$(mktemp); ares-launch -d tv "$id" >/dev/null; sleep "${1:-6}"
for f in $(find .lab/reports -name '*loadreport*' -newer "$mark"); do echo "$(basename $f): $(cat $f)"; done; rm -f "$mark"
