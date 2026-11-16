#!/bin/bash
# Visual check: renders fixed app states and the component gallery on the Mac and compares each with its
# approved image in tools/preview/baseline/ (SSIM at 960x540, through ffmpeg). Exits 1 when any differs.
# A changed state leaves .lab/shots/<name>.png and <name>-diff.png (differences brightened) to look at.
# The baselines use your lab art (app/art); after tools/fetch-art.py, look at the renders and approve.
# usage: tools/preview/shots.sh [--approve] [state...]
P=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$P/../.." && pwd); OUT="$REPO/.lab/shots"; mkdir -p "$OUT"
approve=0; [ "$1" = --approve ] && { approve=1; shift; }
# finds an item in the window's tree by a test (screen ids aren't reachable from the preview)
FIND_JS='function f(o, t) { if (o && t(o)) return o; for (var i = 0; o && i < o.children.length; i++) { var r = f(o.children[i], t); if (r) return r } return null }
var home = f(win.canvas, function (o) { return o.continueWatching !== undefined && o.catalog !== undefined });'
# every state renders on the same day, so the calendar and its baselines don't change with the date
DAY_JS='win.today = "2026-11-16";'
js() {
  echo -n "$DAY_JS "
  case $1 in
    calendar) echo "$FIND_JS home.row = 1; var g = f(home, function (o) { return o.cellWidth !== undefined && o.today !== undefined });"\
                   ' g.showFocus = true; g.select("2026-11-17")' ;;
    show) echo 'win.open()' ;;
    menu) echo 'win.openMenu()' ;;
    title) echo "$FIND_JS f(home, function (o) { return o.jumpTo !== undefined }).jumpTo(2); win.open()" ;;
  esac
}
states=("$@"); [ ${#states[@]} -eq 0 ] && states=(home calendar show menu title gallery)
fail=0
for s in "${states[@]}"; do
  screen="$REPO/app/qml/App.qml"; [ "$s" = gallery ] && screen="$P/gallery.qml"
  rm -f "$OUT/$s.png" "$OUT/$s-diff.png"
  (cd "$REPO/app" && perl -e 'alarm 60; exec @ARGV' /opt/homebrew/opt/qt@5/bin/qml -I "$P/imports" -I "$REPO/app" "$P/shot.qml" -- "$screen" "$OUT/$s.png" "$(js "$s")" 5000 2000 >/dev/null 2>&1)
  [ -f "$OUT/$s.png" ] || { echo "  $s: render failed"; fail=1; continue; }
  base="$P/baseline/$s.png"
  if [ $approve = 1 ]; then
    if ffmpeg -v error -y -i "$OUT/$s.png" -vf scale=960:540 "$base"; then echo "  $s: approved"; else echo "  $s: could not write $base"; fail=1; fi
    continue
  fi
  [ -f "$base" ] || { echo "  $s: no baseline (run with --approve after looking at $OUT/$s.png)"; fail=1; continue; }
  ssim=$(ffmpeg -v info -i "$OUT/$s.png" -i "$base" -lavfi "[0]scale=960:540[a];[a][1]ssim" -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p')
  if awk -v v="$ssim" 'BEGIN { exit !(v >= 0.9995) }'; then echo "  $s: same (SSIM $ssim)"
  else
    ffmpeg -v error -y -i "$OUT/$s.png" -i "$base" -lavfi "[0]scale=960:540[a];[a][1]blend=all_mode=difference,lutrgb=r=val*6:g=val*6:b=val*6" "$OUT/$s-diff.png"
    echo "  $s: CHANGED (SSIM $ssim): $OUT/$s.png, $OUT/$s-diff.png"; fail=1
  fi
done
exit $fail
