#!/bin/zsh
# Builds the perf library, run.sh's once-only step, without quitting a
# live Screens (run.sh quits it to measure): for volunteer.sh and
# edit-storm.sh on the booth Mac while a service plan is up.
#   scripts/perf/library.sh <staged label>
set -u
LABEL=$1
HERE=${0:A:h}
WORK=${MXU_PERF_DIR:-$HOME/Library/Caches/mxu-slides-perf}
BIN="$WORK/Stage/$LABEL.app/Contents/MacOS/Screens"
DOMAIN=com.example.mxuslides.perf
PORT=6989
KEY=$(cat "$HERE"/fixtures/*.json "$HERE/make-library.py" | shasum | cut -c1-10)
LIB=$WORK/library-$KEY
[[ -f $LIB/ready ]] && { print "library ready: $LIB"; exit 0 }
rm -rf "$LIB" && mkdir -p "$LIB"
H=$LIB/home
library="$H/Library/Application Support/Screens/Library"
mkdir -p "$library" && touch "$library/.onboarded-v1"
defaults delete $DOMAIN >/dev/null 2>&1
defaults write $DOMAIN localAPI.enabled -bool YES
defaults write $DOMAIN localAPI.port -int $PORT
defaults write $DOMAIN localAPI.defaultKeyOffered -bool YES
SECRET=$(python3 "$HERE/make-library.py" mint "$library/local-api-tokens.json") || exit 1
CFFIXED_USER_HOME=$H MXU_SKIP_KEYCHAIN=1 MXU_PERF_SCENARIO=idle \
  sandbox-exec -f "$HERE/nonet.sb" "$BIN" > "$LIB/app.log" 2>&1 &
PID=$!
for _ in {1..600}; do
  curl -sf -o /dev/null -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$PORT/v1/documents/presentations" && break
  sleep 0.2
done
python3 "$HERE/make-library.py" build --port $PORT --token "$SECRET" --fixtures "$HERE/fixtures" || { kill $PID; exit 1 }
sleep 3
kill -TERM $PID; sleep 3; kill -KILL $PID 2>/dev/null
defaults delete $DOMAIN >/dev/null 2>&1
touch "$LIB/ready"
print "library built: $LIB"
