#!/bin/bash
# The check before pushing UI or performance changes: the visual check and tools/tests on the Mac, then the current
# build on the TV with the three tours against their frame budget. Starts the lab server if it isn't
# running and stops it again. Exits 1 if anything fails; --mac skips the TV.
# usage: tools/check.sh [--mac]
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO"
fail=0
echo "visual check"; tools/preview/shots.sh || fail=1
# an opacity that a condition switches, in a screen or a component: content that reads the state hiding
# it changes as the fade starts (a scale or a slide that goes with one is on the same item)
echo "fades"; out=$(grep -nE '^[[:space:]]*opacity: .*\?' app/qml/*.qml app/Seimio/UI/*.qml | grep -v '// holds:') && { echo "$out"; echo "  an opacity switched by a condition: use Fade (its content reads \`current\`), or say on the line why what it shows can't change under it (// holds: ...)"; fail=1; }
# What a component has on show becomes another through Swap (AGENTS.md). A value kept for the one on
# its way, or a flag for the one that has gone, is that state kept by hand again, unless its line says
# what it is (`// kept: ...`): a swap told by a call with nothing to wait for, or no swap at all.
echo "swaps"; out=$(grep -nE '^[[:space:]]*property [a-z]+ (pending|incoming|outgoing|gone)[A-Za-z]*\b' app/qml/*.qml app/Seimio/UI/*.qml | grep -v '^app/Seimio/UI/Swap\.qml:' | grep -v '// kept:') && { echo "$out" | cut -c1-200; echo "  a value kept for what is on its way: use Swap (it holds \`shown\` and \`coming\`), or say on the line what it is (// kept: ...)"; fail=1; }
# What is asked of a service goes through the libraries (AGENTS.md, Data). Outside them: no network
# manager or reply of one's own, no counter that says whether an answer is still the one wanted, no
# count of the answers still out, no thread made by hand. The files left out, and why:
#   net.h, pictures.h   the transport and the picture loader themselves (the loader's ticket numbers its jobs)
#   tee.h               the video's bytes pass through it in ranges as the player reads: a transfer, not an answer to keep
#   probes.h            the lab posts its log, and nothing comes back
#   banded_image.h      its ticket hands a picture from the GUI thread to the render thread
#   query.h             `All` and `inTurns` are the count, written once
# (a line with `// wire:` says why a network manager is there: one handed to Net)
echo "requests"; out=$({
  grep -nE 'QNetworkAccessManager|QNetworkReply' native/src/*.h | grep -vE '^native/src/(net|pictures|tee|probes)\.h:' | grep -v '// wire:'
  grep -nE '(ticket|session|serial|generation) *(!=|==) *m_|\+\+m_(ticket|session|serial|refresh|generation)' native/src/*.h | grep -vE '^native/src/(banded_image|pictures|tee)\.h:'
  grep -nE -e '--\*?[A-Za-z_>-]*(left|pending)\b' -e 'make_shared<int>' native/src/*.h | grep -v '^native/src/query\.h:'
  grep -nE 'QThread::create|new QThread' native/src/*.h | grep -v '^native/src/pictures\.h:'
}); [ -n "$out" ] && { echo "$out" | cut -c1-200; echo "  a request, a latest-wins counter, a count of answers or a thread kept by hand: a query (query.h), Net, query::All or query::onWorker does it"; fail=1; }
# (with the previews' recorded answers, as the visual check has them: a test that makes a Catalog asks
# nothing of the network, and tst_pages has titles to ask for)
echo "unit tests"; out=$(SEIMIO_REPLAY="$REPO/tools/preview/api" "$(brew --prefix qt@5)/bin/qmltestrunner" -input tools/tests -import app -import tools/preview/imports 2>&1) || { echo "$out" | grep -E "FAIL|Actual|Expected"; fail=1; }
errs=$(echo "$out" | grep -E "TypeError|ReferenceError|Unable to assign|is not defined" | sort -u | head -4); [ -n "$errs" ] && { echo "  script errors in the tests:"; echo "$errs" | cut -c1-220; fail=1; }
# the C++ libraries' own tests (query.h, net.h, watch.h), with the sanitizers and for leaks
echo "library tests"; tools/tests/native/run.sh || fail=1
[ "$1" = --mac ] && exit $fail

started=""
stop() { [ -n "$started" ] && kill $started 2>/dev/null && wait $started 2>/dev/null; started=""; }
trap stop EXIT; trap 'exit 130' INT TERM
if ! lsof -nP -iTCP:8091 -sTCP:LISTEN >/dev/null 2>&1; then
  python3 -I tools/lab-server.py 8091 >/dev/null 2>&1 & started=$!; sleep 1
fi
echo "deploy"; out=$(tools/deploy.sh 6); rc=$?
{ [ $rc = 0 ] && echo "$out" | grep -q '"ok":true'; } || { echo "  deploy failed or the app didn't report a load"; fail=1; }
for r in home calendar show menu play streams player browse; do
  echo "tour $r"; out=$(tools/tour.sh $r); rc=$?
  echo "$out" | grep -E "total|OVER"; [ $rc = 0 ] || fail=1
done
[ $fail = 0 ] && echo "all checks passed" || echo "CHECKS FAILED"
exit $fail
