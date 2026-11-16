#!/bin/bash
# usage: shot.sh <screen dir> <screen.qml> <out.png> ['<js run on the window>'] [wait ms] [js at ms]
# Renders a lab screen in Qt 5 on the Mac (a window flashes briefly) and saves a screenshot.
P=$(cd "$(dirname "$0")" && pwd)
cd "$1" && perl -e 'alarm 40; exec @ARGV' /opt/homebrew/opt/qt@5/bin/qml -I "$P/imports" "$P/shot.qml" -- "$1/$2" "$3" "${4:-}" "${5:-2500}" "${6:-}" 2>&1 | grep -E "saved|rror|is not|Cannot|Invalid" | head -8
