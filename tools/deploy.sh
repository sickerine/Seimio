#!/bin/bash
# usage: deploy.sh <appdir> <appid> <wait_s> <report-substring>
# Bumps the version, packages, installs, launches, waits, then prints load errors and new reports.
set -u
D=$(cd "$(dirname "$0")" && pwd); cd "$D"
export PATH=~/.nvm/versions/node/v20.20.0/bin:$PATH
app=$1 id=$2 wait=$3 rep=$4
v=$(python3 -c "import json;print(json.load(open('$app/appinfo.json'))['version'])"); n=$(( ${v##*.} + 1 )); nv=${v%.*}.$n
perl -0pi -e "s/\"version\": \"$v\"/\"version\": \"$nv\"/" $app/appinfo.json
mkdir -p ipk; ares-package $app -o ipk >/dev/null || exit 1
ares-launch -d tv --close $id >/dev/null 2>&1
ares-install -d tv ipk/${id}_${nv}_all.ipk >/dev/null || exit 1
s=$(date +%H%M%S); ares-launch -d tv $id >/dev/null; sleep $wait
for f in $(ls reports | awk -v s=$s '$0 >= s' | grep -E "loadreport|$rep"); do
  python3 -c "
import json
d=json.load(open('reports/$f'))
if isinstance(d,list):
    [print(str(e)[:900]) for e in d]
else: print('$f', str(d)[:1500])"
done
