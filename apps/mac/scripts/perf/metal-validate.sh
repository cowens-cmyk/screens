#!/bin/zsh
# Runs the GPU packages' tests with Apple's Metal validation layers on: API
# validation (MTL_DEBUG_LAYER) catches misuse of Metal calls, and shader
# validation (MTL_SHADER_VALIDATION) catches out-of-bounds reads and writes
# inside the shaders. Fails on any validation error; counts the layer's
# performance warnings (redundant state and the like) per kind.
#
#   scripts/perf/metal-validate.sh [Package ...]   (default: the GPU packages)
#
# The app itself can be run the same way through the sandboxed perf harness:
#   MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 scripts/perf/run.sh <commit>
set -u
setopt pipefail nonomatch

HERE=${0:A:h}
MAC=${HERE:h:h}
OUT=${MXU_METAL_VALIDATE_DIR:-$HOME/Library/Caches/mxu-slides-perf/metal-validate}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p "$OUT"

packages=("$@")
(( ${#packages} )) || packages=(RenderEngine OutputEngine MediaEngine)

failed=0
for package in $packages; do
  log="$OUT/$package.log"
  print -r -- "==> $package (log: $log)"
  (cd "$MAC/Packages/$package" &&
    MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
    MTL_DEBUG_LAYER_ERROR_MODE=nslog MTL_DEBUG_LAYER_WARNING_MODE=nslog \
    swift test > "$log" 2>&1)
  tests=$?
  # A validation error names the failing call ("-[MTLDebug…" or "failed
  # assertion"), or comes from shader validation; a test run that stopped
  # on one exits non-zero as well.
  errors=$(grep -cE "failed assertion|Invalid shader|Shader Validation|GPU Address Fault|-\[MTLDebug[A-Za-z]+ [A-Za-z:]+\]:" "$log")
  if (( tests != 0 || errors > 0 )); then
    print -r -- "    FAILED: tests exit $tests, $errors validation errors"
    grep -E -m 10 -A3 "failed assertion|Invalid shader|Shader Validation|GPU Address Fault|-\[MTLDebug" "$log" | sed 's/^/    /'
    failed=1
  else
    print -r -- "    tests pass, no validation errors"
  fi
  # Warnings: the line after the layer's heading says what was redundant.
  warnings=$(grep -A1 -E "Validation$" "$log" | grep -vE "Validation$|^--$" |
    sed -E 's/0x[0-9a-f]+/0x…/g; s/^[0-9-]+ [0-9:.]+ xctest\[[0-9:]+\] //' | sort | uniq -c | sort -rn)
  if [[ -n $warnings ]]; then
    print -r -- "    validation warnings:"
    print -r -- "$warnings" | head -10 | sed 's/^/    /'
  fi
done
exit $failed
