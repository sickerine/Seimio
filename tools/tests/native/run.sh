#!/bin/bash
# The C++ libraries' own tests (native/src/query.h, ...), on the Mac with Homebrew's Qt 5: each
# tools/tests/native/tst_*.cpp is built twice and run twice. Once with the address and undefined-behaviour
# sanitizers, which stop on a use after free or a read past the end; once plain under macOS's `leaks`,
# which fails on any allocation still reachable from nowhere when the tests end. Exits 1 on a failed
# test, a sanitizer report or a leak.
# usage: tools/tests/native/run.sh [name...]      (tst_query; all of them with none)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd); QT=/opt/homebrew/opt/qt@5
OUT="$REPO/.lab/native-tests"; mkdir -p "$OUT"
INC="-I$QT/include -I$QT/include/QtCore -I$QT/include/QtNetwork -I$QT/include/QtTest -I$QT/include/QtGui -I$QT/include/QtQml -I$REPO/native/src -I$OUT"
LIBS="-F$QT/lib -framework QtCore -framework QtNetwork -framework QtTest -framework QtGui -framework QtQml -Wl,-rpath,$QT/lib"
names=("$@"); [ ${#names[@]} -eq 0 ] && names=($(cd "$HERE" && ls tst_*.cpp | sed 's/\.cpp$//'))
fail=0
for t in "${names[@]}"; do
  "$QT/bin/moc" $INC "$HERE/$t.cpp" -o "$OUT/$t.moc" || { fail=1; continue; }
  for h in $(grep -o '#include "[a-z_]*\.h"' "$HERE/$t.cpp" | sed 's/#include "//; s/"//'); do
    grep -q Q_OBJECT "$REPO/native/src/$h" 2>/dev/null && "$QT/bin/moc" $INC "$REPO/native/src/$h" -o "$OUT/moc_${h%.h}.cpp"
  done
  mocs=$(for h in $(grep -o '#include "[a-z_]*\.h"' "$HERE/$t.cpp" | sed 's/#include "//; s/"//'); do [ -f "$OUT/moc_${h%.h}.cpp" ] && echo "$OUT/moc_${h%.h}.cpp"; done)
  clang++ -std=c++17 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -o "$OUT/$t.asan" "$HERE/$t.cpp" $mocs $INC $LIBS 2> "$OUT/$t.build" \
    && clang++ -std=c++17 -g -O1 -o "$OUT/$t.plain" "$HERE/$t.cpp" $mocs $INC $LIBS 2>> "$OUT/$t.build" \
    || { echo "  $t: didn't build"; grep -E "error" "$OUT/$t.build" | head -12; fail=1; continue; }
  out=$(ASAN_OPTIONS=abort_on_error=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$OUT/$t.asan" 2>&1); rc=$?
  echo "$out" | grep -E "^(FAIL|XPASS)|Loc:|Actual|Expected|ERROR: AddressSanitizer|runtime error" | head -20
  [ $rc = 0 ] || fail=1
  echo "  $t: $(echo "$out" | grep -E "^Totals" | sed 's/^Totals: //')"
  leak=$(MallocStackLogging=1 leaks --atExit -- "$OUT/$t.plain" 2>&1); lrc=$?
  if [ $lrc != 0 ]; then echo "  $t: leaks"; echo "$leak" | grep -E "leaks for|ROOT LEAK|^ +[0-9]+ \(" | head -12; fail=1; else echo "  $t: $(echo "$leak" | grep -E "leaks for" | sed 's/^Process [0-9]*: //')"; fi
done
exit $fail
