#!/bin/bash
# Launches the app and checks it's still running a few seconds later.
#
# Everything else in CI proves the app compiles and is packaged. This proves
# it starts, on a Mac it has never seen: GitHub's runners are virtual
# machines with no battery and often no SMC power sensor or IOReport energy
# counters, so it also checks that missing sources hide their metric rather
# than crash.
#
#   Scripts/smoke-test.sh "path/to/Battery Trace.app" [seconds]
set -euo pipefail
APP=${1:?usage: smoke-test.sh path/to/Battery\ Trace.app [seconds]}
SETTLE=${2:-10}
PATTERN="Battery Trace.app/Contents/MacOS"
LOG=$(mktemp)

cleanup() { pkill -f "$PATTERN" 2>/dev/null || true; rm -f "$LOG"; }
trap cleanup EXIT
pkill -f "$PATTERN" 2>/dev/null || true
sleep 1

echo "==> Launching $APP"
"$APP/Contents/MacOS/Battery Trace" > "$LOG" 2>&1 &
PID=$!
echo "==> Waiting ${SETTLE}s to see whether it stays up"
sleep "$SETTLE"
if ! kill -0 "$PID" 2>/dev/null; then
  echo "✗ The app exited within ${SETTLE}s. Output:"
  sed 's/^/    /' "$LOG"
  exit 1
fi
echo "✓ Still running after ${SETTLE}s (pid $PID)"
if [ -s "$LOG" ]; then
  echo "  Output during launch:"
  sed 's/^/    /' "$LOG"
fi
