#!/bin/bash
# Packages app/ (with the built plugins), installs it on the TV and launches it, then
# prints the load result from the lab server; with none, it asks the TV why the app doesn't load
# (app/why.qml). Needs ares-cli on Node 20 and the TV set up as device "tv".
# usage: tools/deploy.sh [seconds to wait]
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
export PATH=~/.nvm/versions/node/v20.20.0/bin:$PATH
mkdir -p app/native .lab/ipk .lab/reports
cp native/out/libseimionative.so native/out/libseimiodata.so native/out/libass.so.9 native/out/qmldir app/native/
id=$(python3 -c "import json;print(json.load(open('app/appinfo.json'))['id'])")
ver=$(python3 -c "import json;print(json.load(open('app/appinfo.json'))['version'])")
# a fresh build number each time, or ares-install keeps the old files
build=$(date +%s); next="${ver%.*}.$((build % 100000))"
tmp=$(mktemp -d); rsync -a --exclude .DS_Store app/ "$tmp/app/"
# the lab server is this Mac, at whatever address the network gave it today (the app is written with .47)
LAB=$(ipconfig getifaddr en0); perl -pi -e "s/192\.168\.1\.47/$LAB/g" "$tmp/app/main.qml" "$tmp/app/why.qml" "$tmp/app/qml/LabProbe.qml"
python3 - "$tmp/app/appinfo.json" "$next" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["version"] = sys.argv[2]; json.dump(d, open(p, "w"), indent=2)
PY
ares-package --no-minify "$tmp/app" -o .lab/ipk >/dev/null || exit 1
# the last five packages are kept (the one before, to put back and compare with): each is 3.7 MB, and
# 461 of them had gathered, 16 GB
ls -t .lab/ipk/*.ipk 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$old"; done
ares-launch -d tv --close "$id" >/dev/null 2>&1
ares-install -d tv ".lab/ipk/${id}_${next}_all.ipk" >/dev/null || exit 1
said() { for f in $(find .lab/reports -name '*loadreport*' -newer "$mark"); do echo "$(basename $f): $(cat $f)"; done; }
mark=$(mktemp); ares-launch -d tv "$id" >/dev/null; sleep "${1:-6}"
out=$(said)
if [ -z "$out" ]; then
  # No word from the app: it closed as it opened (main.qml's root is the app itself, and a file the TV's
  # Qt won't take is no app). The same files with why.qml for their main say what is wrong; that is
  # what is on the TV until the next deploy.
  echo "no load report: asking why"
  why="${ver%.*}.$(((build + 1) % 100000))"
  python3 - "$tmp/app/appinfo.json" "$why" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["version"] = sys.argv[2]; d["main"] = "why.qml"; json.dump(d, open(p, "w"), indent=2)
PY
  ares-package --no-minify "$tmp/app" -o "$tmp" >/dev/null && ares-launch -d tv --close "$id" >/dev/null 2>&1
  ares-install -d tv "$tmp/${id}_${why}_all.ipk" >/dev/null && ares-launch -d tv "$id" >/dev/null && sleep "${1:-6}"
  out=$(said)
fi
echo "$out"; rm -rf "$tmp" "$mark"
