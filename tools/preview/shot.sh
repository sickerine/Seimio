#!/bin/bash
# Renders the app in Qt 5 on the Mac (a window flashes briefly) and saves a 1920x1080 screenshot.
# Stand-ins in imports/ replace the TV-only modules (Eos.Window, Seimio.Native).
# usage: tools/preview/shot.sh <out.png> ['<js run on the app window>'] [shot at ms] [js at ms]
P=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$P/../.." && pwd)
cd "$REPO/app" && perl -e 'alarm 40; exec @ARGV' /opt/homebrew/opt/qt@5/bin/qml -I "$P/imports" -I "$REPO/app" "$P/shot.qml" -- "$REPO/app/qml/App.qml" "$1" "${2:-}" "${3:-4000}" "${4:-}" 2>&1 | grep -E "saved|rror|is not|Cannot|Invalid|unavailable" | head -8
