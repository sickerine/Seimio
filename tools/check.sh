#!/bin/bash
# The check before pushing UI or performance changes: the visual check on the Mac, then the current
# build on the TV with the three tours against their frame budget. Starts the lab server if it isn't
# running and stops it again. Exits 1 if anything fails; --mac skips the TV.
# usage: tools/check.sh [--mac]
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
fail=0
echo "visual check"; tools/preview/shots.sh || fail=1
[ "$1" = --mac ] && exit $fail

started=""
if ! lsof -nP -iTCP:8091 -sTCP:LISTEN >/dev/null 2>&1; then
  python3 -I tools/lab-server.py 8091 >/dev/null 2>&1 & started=$!; sleep 1
fi
echo "deploy"; tools/deploy.sh 6 | grep -q '"ok":true' || { echo "  the app didn't report a load"; fail=1; }
for r in home show menu; do
  echo "tour $r"; out=$(tools/tour.sh $r); rc=$?
  echo "$out" | grep -E "total|OVER"; [ $rc = 0 ] || fail=1
done
[ -n "$started" ] && kill $started
[ $fail = 0 ] && echo "all checks passed" || echo "CHECKS FAILED"
exit $fail
