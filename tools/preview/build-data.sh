#!/bin/bash
# Builds the Seimio.Data plugin (native/src/catalog.h, streams.h, tracks.h) for the Mac previews with Homebrew's Qt 5, into
# tools/preview/imports/Seimio/Data/, so previews run the same data code as the TV.
set -euo pipefail
P=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$P/../.." && pwd); QT=/opt/homebrew/opt/qt@5
OUT="$P/imports/Seimio/Data"; TMP=$(mktemp -d); mkdir -p "$OUT"
INC="-I$QT/include -I$QT/include/QtCore -I$QT/include/QtQml -I$QT/include/QtGui -I$QT/include/QtNetwork -I$REPO/native/src -I$TMP"
"$QT/bin/moc" $INC "$REPO/native/src/catalog.h" -o "$TMP/moc_catalog.cpp"
"$QT/bin/moc" $INC "$REPO/native/src/streams.h" -o "$TMP/moc_streams.cpp"
"$QT/bin/moc" $INC "$REPO/native/src/tracks.h" -o "$TMP/moc_tracks.cpp"
"$QT/bin/moc" $INC "$REPO/native/src/data_plugin.cpp" -o "$TMP/data_plugin.moc"
clang++ -std=c++17 -O2 -fPIC -shared -o "$OUT/libseimiodata.dylib" "$REPO/native/src/data_plugin.cpp" "$TMP/moc_catalog.cpp" "$TMP/moc_streams.cpp" "$TMP/moc_tracks.cpp" $INC \
  -DQT_NO_DEBUG -DQT_PLUGIN -F"$QT/lib" -framework QtCore -framework QtQml -framework QtGui -framework QtNetwork
printf 'module Seimio.Data\nplugin seimiodata\n' > "$OUT/qmldir"
rm -rf "$TMP"; echo "built $OUT/libseimiodata.dylib"
