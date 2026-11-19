#!/bin/bash
# Writes the app's icon and splash screen into app/ from tools/brand.qml (on the Mac, with Homebrew's
# Qt 5). Run it after changing the mark; the three files are checked in, as the TV package needs them.
# (Asked again when nothing was written: macOS doesn't draw a window that is covered.)
REPO=$(cd "$(dirname "$0")/.." && pwd)
for try in 1 2 3; do
  out=$(cd "$REPO/app" && perl -e 'alarm 25; exec @ARGV' /opt/homebrew/opt/qt@5/bin/qml -I "$REPO/tools/preview/imports" -I "$REPO/app" "$REPO/tools/brand.qml" -- "$REPO/app" 2>&1)
  case "$out" in *saved*) echo "wrote app/icon.png, app/icon-large.png, app/splash.png"; exit 0;; esac
done
echo "nothing written:"; echo "$out" | tail -5; exit 1
