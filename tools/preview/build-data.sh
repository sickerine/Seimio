#!/bin/bash
# Builds the Seimio.Data plugin (native/src/data_plugin.cpp and Stremio's core, core/) for the Mac previews with Homebrew's Qt 5, into
# tools/preview/imports/Seimio/Data/, so previews run the same data code as the TV.
set -euo pipefail
P=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$P/../.." && pwd); QT=/opt/homebrew/opt/qt@5
OUT="$P/imports/Seimio/Data"; TMP=$(mktemp -d); mkdir -p "$OUT"
INC="-I$QT/include -I$QT/include/QtCore -I$QT/include/QtQml -I$QT/include/QtGui -I$QT/include/QtNetwork -I$REPO/native/src -I$TMP"
(cd "$REPO/core" && cargo build --release --lib 2>&1 | grep -E "^(error|warning: unused)|^ *--> " || true)
for h in catalog franchise live streams tracks skip http core account; do "$QT/bin/moc" $INC "$REPO/native/src/$h.h" -o "$TMP/moc_$h.cpp"; done
"$QT/bin/moc" $INC "$REPO/native/src/data_plugin.cpp" -o "$TMP/data_plugin.moc"
clang++ -std=c++17 -O2 -fPIC -shared -o "$OUT/libseimiodata.dylib" "$REPO/native/src/data_plugin.cpp" "$TMP"/moc_*.cpp $INC \
  "$REPO/core/target/release/libseimio_core.a" \
  -DQT_NO_DEBUG -DQT_PLUGIN -F"$QT/lib" -framework QtCore -framework QtQml -framework QtGui -framework QtNetwork -framework CoreFoundation
printf 'module Seimio.Data\nplugin seimiodata\n' > "$OUT/qmldir"
rm -rf "$TMP"; echo "built $OUT/libseimiodata.dylib"
