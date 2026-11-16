#!/bin/zsh
# Where the page lands after a plan-list click, far down and far back up.
#
#   MXU_PERF_BUILD_ONLY=1 scripts/perf/run.sh <commit>   # build and stage it first
#   scripts/perf/landing.sh <commit-label>
#
# Runs the staged perf build on the Present page and clicks plan rows through
# the app's own event queue (the `input` signal, so it works with the screen
# locked): Bulk Deck 008, back up to 000, down to 008, up to 002. Prints
# where each landed two seconds later and exits 1 unless every one has its
# item's top at the top of the page. A jump up used to land a grid's height
# short: the scroll anchor was on the sticky header, which sits at the bottom
# of its section while stuck. Row positions are for the scenario's own
# window (1480x900) and plan.
set -u
LABEL=$1
HERE=${0:A:h}
WORK=${MXU_PERF_DIR:-$HOME/Library/Caches/mxu-slides-perf}
BIN="$WORK/Stage/$LABEL.app/Contents/MacOS/Screens"
[[ -x $BIN ]] || { print -r -- "no staged build at $WORK/Stage/$LABEL.app" >&2; exit 2 }
LIB=$(ls -d $WORK/library-*/home 2>/dev/null | head -1)
[[ -n $LIB ]] || { print -r -- "no perf library yet (run.sh builds it once)" >&2; exit 2 }
caffeinate -dimsu -t 120 &
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
for y in 818 506 818 584; do
  print -r -- "click 93 $y" > $HOME_DIR/perf-input.txt
  notifyutil -p com.example.mxuslides.perf.input
  sleep 2.6
done
kill -TERM $PID 2>/dev/null; sleep 1; kill -KILL $PID 2>/dev/null
defaults delete com.example.mxuslides.perf >/dev/null 2>&1
LANDED=$(grep -hE 'present\.focus\.landed — 2 s' "$CRUMBS"/breadcrumbs-*.log)
print -r -- "$LANDED" | sed -E 's/^.*wanted [0-9A-F-]+ //; s/; at the top: [0-9A-F-]+/ | at the top:/' | cut -c1-120
[[ $(print -r -- "$LANDED" | grep -c 'its top at 0 pt') == 4 ]] || { print -r -- "landing: not every jump landed on its item's top" >&2; exit 1 }
