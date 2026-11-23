#!/bin/zsh
# Editing a deck while it is on the plan page, measured: forty slides from
# Bulk Deck 001 dropped one by one onto Bulk Deck 000 (8 slides growing to
# 48), 0.9 s apart, then six seconds to settle. Same output as
# volunteer.sh; perf.mark counts SlideThumbnailView bodies, which grew
# with the deck while a tile's picture was keyed by the deck's stamp.
#   scripts/perf/edit-storm.sh <label> [round]
set -u
LABEL=$1
ROUND=${2:-1}
HERE=${0:A:h}
WORK=${MXU_PERF_DIR:-$HOME/Library/Caches/mxu-slides-perf}
APP=$WORK/Stage/$LABEL.app
BIN="$APP/Contents/MacOS/Screens"
DOMAIN=com.example.mxuslides.perf
OUT=$WORK/runs/edit-$LABEL-r$ROUND-$(date +%H%M%S)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
[[ -x $BIN ]] || { print -r -- "no staged build at $APP" >&2; exit 2 }
LIB=$(ls -d $WORK/library-*${MXU_PERF_BIG:+-big}/home 2>/dev/null | grep -v -- "${MXU_PERF_BIG:+NOTHING}${MXU_PERF_BIG:--big/}" | head -1)
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

xcrun xctrace record --template 'Time Profiler' --attach $PID --time-limit 70s \
  --output $OUT/t.trace > $OUT/xctrace.log 2>&1 &
TRACER=$!
sleep 4
mark start
mark drops
for i in {1..40}; do
  for n in welcome live screens services edit import account feedback; do :; done
  N=(welcome live screens services edit import account feedback)
  input "drop tile 1 0.3 mxuslide::bulk001::bulk001.${N[$(( (i % 8) + 1 ))]}"; sleep 0.9
done
mark settle; sleep 6
mark end
wait $TRACER
cp "$CRUMBS"/breadcrumbs-*.log $OUT/ 2>/dev/null
kill -TERM $PID 2>/dev/null; sleep 2; kill -KILL $PID 2>/dev/null
defaults delete $DOMAIN >/dev/null 2>&1
python3 -I $HERE/volunteer-analyze.py $OUT
print -r -- "==> $OUT"
