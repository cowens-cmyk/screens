#!/bin/zsh
# Each screen comes back on its outputs after a quit, and after Screens is
# killed outright (a crash, a power cut).
#
#   MXU_PERF_BUILD_ONLY=1 scripts/perf/run.sh <commit>   # build and stage it first
#   scripts/perf/outputs.sh <commit-label>
#
# Runs the staged perf build three times on one sandbox home, through the
# app's own `input` signal (so it works with the screen locked):
#   1. puts the booth's outputs on as the church has them (DeckLink ports
#      LED Wall - 1 Audience, Stage Display - 2 Stage, EXTRA - 4 Side TVs,
#      Key & Fill - 5 Livestream) plus a display, then quits as the menu does;
#   2. opens again, checks every screen is back on the same outputs, moves
#      the display to Side TVs as well, then is killed with no warning;
#   3. opens again and checks that too came back.
# The ports and the display don't exist on this Mac: Screens keeps a choice
# for an output that isn't there yet, as the booth's are at the moment it
# opens. Choosing Side TVs for EXTRA - 4 also turns the Side TVs on.
# Exits 1 if anything came back different.
set -u
LABEL=$1
HERE=${0:A:h}
WORK=${MXU_PERF_DIR:-$HOME/Library/Caches/mxu-slides-perf}
BIN="$WORK/Stage/$LABEL.app/Contents/MacOS/Screens"
[[ -x $BIN ]] || { print -r -- "no staged build at $WORK/Stage/$LABEL.app" >&2; exit 2 }
LIB=$(ls -d $WORK/library-*/home 2>/dev/null | head -1)
[[ -n $LIB ]] || { print -r -- "no perf library yet (run.sh builds it once)" >&2; exit 2 }
DOMAIN=com.example.mxuslides.perf
caffeinate -dimsu -t 240 &
AWAKE=$!
HOME_DIR=$WORK/homes/outputs
rm -rf $HOME_DIR && cp -cR $LIB $HOME_DIR
CRUMBS="$HOME_DIR/Library/Application Support/Screens/Diagnostics"
rm -rf "$CRUMBS"
defaults delete $DOMAIN >/dev/null 2>&1
setopt nonomatch

PID=
launch() {
  local before=$(cat "$CRUMBS"/breadcrumbs-*.log 2>/dev/null | grep -c 'perf\.scenario\.ready')
  CFFIXED_USER_HOME=$HOME_DIR MXU_SKIP_KEYCHAIN=1 MXU_PERF_SCENARIO=present \
    sandbox-exec -f $HERE/nonet.sb $BIN > /dev/null 2>&1 &
  PID=$!
  for _ in {1..1200}; do
    (( $(cat "$CRUMBS"/breadcrumbs-*.log 2>/dev/null | grep -c 'perf\.scenario\.ready') > before )) && break
    sleep 0.1
  done
  sleep 3
}
input() {
  print -r -- "$*" > $HOME_DIR/perf-input.txt
  notifyutil -p $DOMAIN.input
  sleep ${WAIT:-0.8}
}
routes() {
  input routes
  grep -h 'perf\.routes' "$CRUMBS"/breadcrumbs-*.log | tail -1 | sed -E 's/^.*perf\.routes — //'
}
FAILED=0
check() {  # check LABEL ACTUAL EXPECTED
  if [[ $2 == $3 ]]; then
    print -r -- "ok    $1"
  else
    print -r -- "FAIL  $1:"
    print -r -- "        got    $2"
    print -r -- "        wanted $3"
    FAILED=1
  fi
}

DISPLAY_ID=00000000-0000-0000-0000-0000000000AA
WANT1="audience=port:LED_Wall_-_1 livestream=port:Key_&_Fill_-_5 stage=port:Stage_Display_-_2 sideTVs=port:EXTRA_-_4"
WANT2="audience=port:LED_Wall_-_1 livestream=port:Key_&_Fill_-_5 stage=port:Stage_Display_-_2 sideTVs=display:$DISPLAY_ID"

launch
input port LED_Wall_-_1 4181696656 audience
input port Stage_Display_-_2 4181696660 stage
input port EXTRA_-_4 4181696661 sideTVs
input port 'Key_&_Fill_-_5' 4181696658 livestream
check "set up as the booth has it" "$(routes)" "$WANT1"
input quit
for _ in {1..100}; do kill -0 $PID 2>/dev/null || break; sleep 0.1; done
kill -0 $PID 2>/dev/null && { print -r -- "FAIL  Screens didn't quit"; kill -KILL $PID; FAILED=1 }

launch
check "after a quit, every screen is back on its port" "$(routes)" "$WANT1"
input display $DISPLAY_ID sideTVs
check "Side TVs moved to a display" "$(routes)" "$WANT2"
sleep 2
kill -KILL $PID 2>/dev/null; sleep 1

launch
check "after Screens was killed outright, the move is kept" "$(routes)" "$WANT2"
input quit
for _ in {1..100}; do kill -0 $PID 2>/dev/null || break; sleep 0.1; done
kill -KILL $PID 2>/dev/null
kill $AWAKE 2>/dev/null
defaults delete $DOMAIN >/dev/null 2>&1
[[ $FAILED == 0 ]] || { print -r -- "outputs: a check failed" >&2; exit 1 }
print -r -- "outputs: every screen came back on its outputs"
