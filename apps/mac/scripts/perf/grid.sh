#!/bin/zsh
# A slide grid's one drop target and one right-click menu, checked.
#
#   MXU_PERF_BUILD_ONLY=1 scripts/perf/run.sh <commit>   # build and stage it first
#   scripts/perf/grid.sh <commit-label>
#
# A grid has one drop target and one menu for all its tiles and works out
# the tile under the pointer itself (SlideGridDropDelegate,
# SlideGridMenuPress). This runs the staged perf build on the Present page
# and, through the app's own `input` signal (so it works with the screen
# locked), checks on the first deck that:
#   - a right-click on each tile builds that tile's menu, also when the
#     clicks come 60 ms apart on different tiles, and a click in the gap
#     between tiles opens none;
#   - a slide dropped on a tile's near half goes before it, on its far half
#     after it, and in a gap beside the nearest tile;
#   - something that isn't a picture, a video or a slide is taken on a tile
#     and refused in a gap;
#   - a picture file dropped in a gap becomes a new slide.
# The drops are sent to the view SwiftUI lays over the drop target, with the
# calls AppKit makes for a real drag, so the app's own drop code runs; what
# they can't show is the drag itself (picking a slide up, the picture that
# follows the pointer). Exits 1 if any check fails.
set -u
LABEL=$1
HERE=${0:A:h}
WORK=${MXU_PERF_DIR:-$HOME/Library/Caches/mxu-slides-perf}
BIN="$WORK/Stage/$LABEL.app/Contents/MacOS/Screens"
[[ -x $BIN ]] || { print -r -- "no staged build at $WORK/Stage/$LABEL.app" >&2; exit 2 }
LIB=$(ls -d $WORK/library-*/home 2>/dev/null | head -1)
[[ -n $LIB ]] || { print -r -- "no perf library yet (run.sh builds it once)" >&2; exit 2 }
caffeinate -dimsu -t 180 &
AWAKE=$!
HOME_DIR=$WORK/homes/present
rm -rf $HOME_DIR && cp -cR $LIB $HOME_DIR
rm -rf "$HOME_DIR/Library/Application Support/Screens/Diagnostics"
defaults delete com.example.mxuslides.perf >/dev/null 2>&1
CFFIXED_USER_HOME=$HOME_DIR MXU_SKIP_KEYCHAIN=1 MXU_PERF_SCENARIO=present \
  sandbox-exec -f $HERE/nonet.sb $BIN > /dev/null 2>&1 &
PID=$!
CRUMBS="$HOME_DIR/Library/Application Support/Screens/Diagnostics"
setopt nonomatch
for _ in {1..1200}; do
  grep -qE 'perf\.scenario\.(ready|failed)' "$CRUMBS"/breadcrumbs-*.log 2>/dev/null && break
  sleep 0.1
done
sleep 3

FAILED=0
input() {
  print -r -- "$*" > $HOME_DIR/perf-input.txt
  notifyutil -p com.example.mxuslides.perf.input
  sleep ${WAIT:-0.6}
}
crumbs() { grep -hE "$1" "$CRUMBS"/breadcrumbs-*.log 2>/dev/null }
check() {  # check LABEL ACTUAL EXPECTED-PATTERN
  if [[ $2 =~ $3 ]]; then
    print -r -- "ok    $1"
  else
    print -r -- "FAIL  $1: got '${2:-nothing}', wanted /$3/"
    FAILED=1
  fi
}
# The slide a right-click on tile N builds its menu for.
slide_at() {
  input menu tile $1 0.5
  crumbs 'perf\.menu\.built' | tail -1 | sed -E 's/^.* tile ([0-9]+) /\1 /'
}

# The first deck's slides, in order: welcome, live, screens, services, edit.
for n in 0 1 2 3 4; do
  check "menu on tile $n is tile $n's" "$(slide_at $n)" "^$n bulk000\."
done
BEFORE=$(crumbs 'perf\.menu\.built' | wc -l)
for _ in {1..10}; do
  for n in 0 4 2; do WAIT=0.06 input menu tile $n 0.5; done
done
sleep 0.5
RAPID=$(crumbs 'perf\.menu\.built' | tail -n +$((BEFORE + 1)) | sed -E 's/^.* tile ([0-9]+) .*$/\1/' | tr -d '\n')
check "30 right-clicks 60 ms apart each get their own tile" "$RAPID" "^(042){10}$"
input menu tile 0 1.03
check "no menu in the gap between tiles" "$(crumbs 'perf\.menu —' | tail -1)" ": 0 items"

WAIT=1.2 input drop tile 2 0.3 mxuslide::bulk000::bulk000.edit
check "a slide on a tile's near half goes before it" "$(crumbs 'grid\.drop\.tile' | tail -1)" "before\(2\)"
check "  and is there afterwards" "$(slide_at 2)" "^2 bulk000\.edit"
WAIT=1.2 input drop tile 2 0.7 mxuslide::bulk000::bulk000.welcome
check "a slide on a tile's far half goes after it" "$(crumbs 'grid\.drop\.tile' | tail -1)" "after\(2\)"
check "  and is there afterwards" "$(slide_at 2)" "^2 bulk000\.welcome"
WAIT=1.2 input drop tile 0 1.03 mxuslide::bulk000::bulk000.services
check "a slide in a gap goes beside the nearest tile" "$(crumbs 'grid\.gapDrop' | tail -1)" "before\(1\)"
check "  and is there afterwards" "$(slide_at 1)" "^1 bulk000\.services"

input dragover tile 2 0.1 pltrk::a::b
check "a track is taken on a tile" "$(crumbs 'perf\.drop' | tail -1)" "updated 1 held"
input dragover tile 0 1.03 pltrk::a::b
check "a track is refused in a gap" "$(crumbs 'perf\.drop' | tail -1)" "updated 0 held"
input dragend

sips -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns \
  --out $HOME_DIR/grid-drop.png >/dev/null 2>&1
WAIT=2.5 input drop tile 0 1.03 file:$HOME_DIR/grid-drop.png
check "a picture file in a gap is taken there" "$(crumbs 'grid\.gapDrop' | tail -1)" "before\(1\) files=1"
check "  and becomes a ninth slide" "$(crumbs 'grid\.drop\.relaid' | tail -1)" "9 slides"

kill -TERM $PID 2>/dev/null; sleep 1; kill -KILL $PID 2>/dev/null
kill $AWAKE 2>/dev/null
defaults delete com.example.mxuslides.perf >/dev/null 2>&1
[[ $FAILED == 0 ]] || { print -r -- "grid: a check failed" >&2; exit 1 }
print -r -- "grid: every check passed"
