#!/bin/bash
# Visual check: renders fixed app states and the component gallery on the Mac and compares each with its
# approved image in tools/preview/baseline/ (SSIM at 960x540, through ffmpeg). Exits 1 when any differs.
# A changed state leaves .lab/shots/<name>.png and <name>-diff.png (differences brightened) to look at.
# The app fetches everything live (native/src/live.h), so the renders replay recorded answers from
# tools/preview/api/ (SEIMIO_REPLAY) and stay the same from day to day; --record fetches and records what's
# missing (delete the folder to record afresh, then look at the renders and approve). The account is the
# core's storage in tools/preview/account/ (AGENTS.md says how it is signed in): it decides what Continue
# Watching holds.
# usage: tools/preview/shots.sh [--approve | --record] [state...]
P=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$P/../.." && pwd); OUT="$REPO/.lab/shots"; mkdir -p "$OUT"
approve=0; [ "$1" = --approve ] && { approve=1; shift; }
[ "$1" = --record ] && { export SEIMIO_RECORD=1; shift; }
export SEIMIO_REPLAY="$P/api"
# finds an item in the window's tree by a test (screen ids aren't reachable from the preview)
FIND_JS='function f(o, t) { if (o && t(o)) return o; for (var i = 0; o && i < o.children.length; i++) { var r = f(o.children[i], t); if (r) return r } return null }
var home = f(win.canvas, function (o) { return o.continueWatching !== undefined && o.catalog !== undefined });'
# every state renders on the same day, so the calendar and its baselines don't change with the date; the
# app starts on that day, so nothing rebuilds when it's set (gallery.qml takes no properties)
DAY='{"today": "2026-11-16"}'
# the backdrops' slow zoom rests, so a state looks the same whenever it's captured (the quick menu's frost
# froze a different moment of it each run)
STILL_JS='(function s(o) { if (o.decodeSize !== undefined) o.still = true; for (var i = 0; i < o.children.length; i++) s(o.children[i]) })(win.canvas || win.contentItem);'
js() {
  case "$1" in gallery*) ;; *) printf '%s ' "$STILL_JS";; esac
  case $1 in
    calendar) echo "$FIND_JS home.row = 1; var g = f(home, function (o) { return o.cellWidth !== undefined && o.today !== undefined });"\
                   ' g.showFocus = true; g.select("2026-11-17")' ;;
    show) echo 'win.open()' ;;
    menu) echo 'win.openMenu()' ;;
    title) echo "$FIND_JS f(home, function (o) { return o.jumpTo !== undefined }).jumpTo(2); win.open()" ;;
    profile) echo 'win.layer = "profile"; win.profileOpen = true' ;;
  esac
}
states=("$@"); [ ${#states[@]} -eq 0 ] && states=(home calendar show menu title profile signin gallery gallery2)
fail=0
for s in "${states[@]}"; do
  screen="$REPO/app/qml/App.qml"; day="$DAY"; case "$s" in gallery*) screen="$P/$s.qml"; day="";; esac
  # signed out: the core on an empty folder, so the app is its sign-in screen (the code is a recorded answer)
  unset SEIMIO_ACCOUNT; [ "$s" = signin ] && { rm -rf "$OUT/signed-out"; export SEIMIO_ACCOUNT="$OUT/signed-out"; }
  # a render that fetched an image caught it whenever it arrived (the data plugin says "fetched"); the next
  # one has it on disk
  for try in 1 2; do
    rm -f "$OUT/$s.png" "$OUT/$s-diff.png"
    log=$(cd "$REPO/app" && perl -e 'alarm 60; exec @ARGV' /opt/homebrew/opt/qt@5/bin/qml -I "$P/imports" -I "$REPO/app" "$P/shot.qml" -- "$screen" "$OUT/$s.png" "$(js "$s")" 5000 2000 "$day" 2>&1)
    case "$log" in *"fetched "*) ;; *) break;; esac
  done
  [ -f "$OUT/$s.png" ] || { echo "  $s: render failed"; fail=1; continue; }
  # a handler that threw or a binding that read nothing while it rendered (the TV's tours catch the same)
  errs=$(printf '%s\n' "$log" | grep -E "TypeError|ReferenceError|Unable to assign|is not defined" | sed -E 's/^file:[^ ]*\/(app|tools)\//\1\//' | sort -u | head -4)
  [ -n "$errs" ] && { echo "  $s: script errors"; printf '%s\n' "$errs" | cut -c1-220 | sed 's/^/    /'; fail=1; }
  base="$P/baseline/$s.png"
  if [ $approve = 1 ]; then
    if ffmpeg -v error -y -i "$OUT/$s.png" -vf scale=960:540 "$base"; then echo "  $s: approved"; else echo "  $s: could not write $base"; fail=1; fi
    continue
  fi
  [ -f "$base" ] || { echo "  $s: no baseline (run with --approve after looking at $OUT/$s.png)"; fail=1; continue; }
  ssim=$(ffmpeg -v info -i "$OUT/$s.png" -i "$base" -lavfi "[0]scale=960:540[a];[a][1]ssim" -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p')
  if awk -v v="$ssim" 'BEGIN { exit !(v >= 0.9995) }'; then echo "  $s: same (SSIM $ssim)"
  else
    ffmpeg -v error -y -i "$OUT/$s.png" -i "$base" -lavfi "[0]scale=960:540,format=rgb24[a];[1]format=rgb24[b];[a][b]blend=all_mode=difference,lutrgb=r=val*6:g=val*6:b=val*6" "$OUT/$s-diff.png"
    echo "  $s: CHANGED (SSIM $ssim): $OUT/$s.png, $OUT/$s-diff.png"; fail=1
  fi
done
exit $fail
