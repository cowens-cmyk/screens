#!/bin/zsh
# What volunteers do on the Present page, measured: slide clicks, ten
# seconds idle, wheel scrolls down and up the plan page (twice), plan-list
# picks. Runs the staged perf build (MXU_PERF_BUILD_ONLY=1 run.sh, then
# library.sh once)
# beside a live Screens, which it leaves alone, records Time Profiler over
# the lot and prints, per phase, main-thread busy ms and the busy runs over
# 9 / 17 / 33 ms (volunteer-analyze.py; --phase NAME and --under SYMBOL
# there break a phase down). perf.mark lines in the run's breadcrumbs
# count the bodies each phase re-ran. MXU_EXP_* variables reach the app, for
# switches a perf build reads. Compare builds interleaved, twice.
#   scripts/perf/volunteer.sh <label> [round]
set -u
LABEL=$1
ROUND=${2:-1}
HERE=${0:A:h}
WORK=${MXU_PERF_DIR:-$HOME/Library/Caches/mxu-slides-perf}
APP=$WORK/Stage/$LABEL.app
BIN="$APP/Contents/MacOS/Screens"
DOMAIN=com.example.mxuslides.perf
OUT=$WORK/runs/vol-$LABEL-r$ROUND-$(date +%H%M%S)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
[[ -x $BIN ]] || { print -r -- "no staged build at $APP" >&2; exit 2 }
LIB=$(ls -d $WORK/library-*/home 2>/dev/null | head -1)
[[ -n $LIB ]] || { print -r -- "no perf library yet" >&2; exit 2 }
mkdir -p $OUT
caffeinate -dimsu -t 150 &
HOME_DIR=$WORK/homes/vol
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
sleep 6

mark() { notifyutil -p com.example.mxuslides.perf.mark; sleep 0.2; print -r -- "$(python3 -c 'import time; print(f"{time.time():.3f}")') $1" >> $OUT/phases.txt }
input() { print -r -- "$1" > "$HOME_DIR/perf-input.txt"; notifyutil -p com.example.mxuslides.perf.input }

xcrun xctrace record --template 'Time Profiler' --attach $PID --time-limit 80s \
  --output $OUT/t.trace > $OUT/xctrace.log 2>&1 &
TRACER=$!
sleep 4
mark start
mark tiles
for i in 1 2 3 5 4 6 8 7; do input "click tile $i 0.5"; sleep 1.2; done
mark idle; sleep 10
mark scroll
input "scroll -50 70"; sleep 2.5
input "scroll 50 70"; sleep 2.5
input "scroll -50 70"; sleep 2.5
input "scroll 50 70"; sleep 2.5
mark picks
for _ in {1..8}; do notifyutil -p com.example.mxuslides.perf.pick; sleep 1.5; done
mark end
wait $TRACER
cp "$CRUMBS"/breadcrumbs-*.log $OUT/ 2>/dev/null
kill -TERM $PID 2>/dev/null; sleep 2; kill -KILL $PID 2>/dev/null
defaults delete $DOMAIN >/dev/null 2>&1
python3 -I $HERE/volunteer-analyze.py $OUT
print -r -- "==> $OUT"
