#!/bin/zsh
# Plan-list clicks on the Present page, measured.
#
#   MXU_PERF_BUILD_ONLY=1 scripts/perf/run.sh <commit>   # build and stage it first
#   scripts/perf/present.sh <commit-label>
#
# Runs the staged perf build (no network, its own copy of the 302-deck
# library) with MXU_PERF_SCENARIO=present: a Sunday-shaped plan on the
# Present page. It then picks twelve plan items in turn, as plan-list clicks
# do, 1.5 s apart, with a body count (perf.mark) after each and a 20 s
# `sample` over the lot. Look in the output folder's breadcrumbs for
# perf.pass / perf.hitch after each perf.pick, perf.mark for the views each
# pick re-ran, and present.focus.landed for where the page ended up.
# The display must be awake: an animated scroll doesn't move while it sleeps
# (caffeinate -dimsu keeps it on).
set -u
LABEL=$1
HERE=${0:A:h}
WORK=${MXU_PERF_DIR:-$HOME/Library/Caches/mxu-slides-perf}
APP=$WORK/Stage/$LABEL.app
BIN="$APP/Contents/MacOS/Screens"
DOMAIN=com.example.mxuslides.perf
OUT=$WORK/runs/present-$LABEL-$(date +%Y%m%d-%H%M%S)
[[ -x $BIN ]] || { print -r -- "no staged build at $APP (MXU_PERF_BUILD_ONLY=1 run.sh first)" >&2; exit 2 }
LIB=$(ls -d $WORK/library-*/home 2>/dev/null | head -1)
[[ -n $LIB ]] || { print -r -- "no perf library yet (run.sh builds it once)" >&2; exit 2 }
mkdir -p $OUT
caffeinate -dimsu -t 120 &
HOME_DIR=$WORK/homes/present
rm -rf $HOME_DIR && cp -cR $LIB $HOME_DIR
rm -rf "$HOME_DIR/Library/Application Support/Screens/Diagnostics"
defaults delete $DOMAIN >/dev/null 2>&1
CFFIXED_USER_HOME=$HOME_DIR MXU_SKIP_KEYCHAIN=1 MXU_PERF_SCENARIO=present \
  sandbox-exec -f $HERE/nonet.sb $BIN > $OUT/app.log 2>&1 &
PID=$!
CRUMBS="$HOME_DIR/Library/Application Support/Screens/Diagnostics"
setopt nonomatch
for _ in {1..1200}; do
  grep -qE 'perf\.scenario\.(ready|failed)' "$CRUMBS"/breadcrumbs-*.log 2>/dev/null && break
  sleep 0.1
done
grep -hE 'perf\.scenario\.(ready|failed)' "$CRUMBS"/breadcrumbs-*.log 2>/dev/null | tail -1
sleep 3
sample $PID 20 1 -mayDie -file $OUT/sample.txt >/dev/null 2>&1 &
SAMPLER=$!
notifyutil -p com.example.mxuslides.perf.mark; sleep 0.3
for _ in {1..12}; do
  notifyutil -p com.example.mxuslides.perf.pick; sleep 1.5
  notifyutil -p com.example.mxuslides.perf.mark; sleep 0.2
done
wait $SAMPLER
cp "$CRUMBS"/breadcrumbs-*.log $OUT/
kill -TERM $PID 2>/dev/null; sleep 2; kill -KILL $PID 2>/dev/null
defaults delete $DOMAIN >/dev/null 2>&1
grep -hE 'perf\.(pick|pass|hitch|mark) ' $OUT/breadcrumbs-*.log | cut -c1-160
print -r -- "==> $OUT"
