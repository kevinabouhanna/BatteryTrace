#!/bin/bash
# Ranks apps with Battery Trace and with top's POWER column (Activity
# Monitor's Energy Impact) under controlled loads. Needs no password.
#
#   Scripts/validate.sh            idle, CPU loop, GPU load
#   Scripts/validate.sh cpu        one scenario
set -euo pipefail
cd "$(dirname "$0")/.."
BT=BatteryTraceKit/.build/release/bttrace
[ -x "$BT" ] || (cd BatteryTraceKit && swift build -c release --product bttrace)
OUT=validation/$(date +%Y%m%d-%H%M%S)-top
mkdir -p "$OUT"
SCENARIOS=${*:-idle cpu gpu}

for scenario in $SCENARIOS; do
  load=""
  case $scenario in
    idle) ;;
    cpu) "$BT" stress cpu --threads 4 --seconds 30 > /dev/null & load=$! ;;
    gpu) "$BT" stress gpu --seconds 30 > /dev/null & load=$! ;;
    *) echo "unknown scenario $scenario"; exit 1 ;;
  esac
  sleep 3
  "$BT" compare-top --label "$scenario" --interval 5 --count 4 | tee "$OUT/$scenario.txt"
  [ -n "$load" ] && wait "$load" 2>/dev/null || true
  echo
done
echo "Saved to $OUT"
