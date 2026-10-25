#!/bin/bash
# What Battery Trace itself costs, measured from outside: CPU time (ps),
# Energy Impact and its rank among all processes (top's POWER, the figure
# Activity Monitor shows), memory footprint, wakeups. Popover closed for
# MINUTES (default 5), then open for 90 s. Also asks Battery Trace's own
# history where it ranks itself.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${APP:-build/DerivedData/Build/Products/Release/Battery Trace.app}"
MINUTES=${MINUTES:-5}
EXE="$APP/Contents/MacOS/Battery Trace"
DB="$HOME/Library/Application Support/Battery Trace/history.sqlite"

cpu_seconds() { ps -o time= -p "$1" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
# "Battery Trace [123]: 64-bit    Footprint: 9.1 MB (16384 bytes per page)"
footprint_mb() { footprint -p "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]*B\).*/\1 \2/p' | head -1 | awk '{ v=$1; if ($2=="KB") v/=1024; if ($2=="GB") v*=1024; if ($2=="B") v/=1048576; print v }'; }

measure() { # label seconds pid
  local label=$1 seconds=$2 pid=$3
  local c0; c0=$(cpu_seconds "$pid")
  # top's second sample covers the whole span: CPU%, POWER, wakeups.
  local line; line=$(top -l 2 -s "$seconds" -stats pid,cpu,power,idlew,mem -o power -n 400 | awk -v p="$pid" 'BEGIN{n=0} /^PID/{n++; rank=0; next} n==2 && $1 ~ /^[0-9]+$/ {rank++; if ($1==p) {print rank, $2, $3, $4, $5; exit}}')
  local c1; c1=$(cpu_seconds "$pid")
  read -r rank cpu power idlew mem <<< "$line"
  printf "%-16s CPU %.3f%% of one core (ps: %.2f s in %d s) · top: CPU %s%%, Energy Impact %s, rank %s of all processes, %s idle wakeups · footprint %.1f MB\n" \
    "$label" "$(echo "($c1 - $c0) * 100 / $seconds" | bc -l)" "$(echo "$c1 - $c0" | bc -l)" "$seconds" "$cpu" "$power" "$rank" "$idlew" "$(footprint_mb "$pid")"
}

# Through LaunchServices, as a real launch: Battery Trace gets its own
# coalition rather than joining this terminal's.
launch() {
  open -n "$APP" --args "$@"
  for _ in $(seq 50); do PID=$(pgrep -nf "$EXE" || true); [ -n "$PID" ] && return; sleep 0.2; done
  echo "Battery Trace didn't start"; exit 1
}
stop() { kill "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done; }

pkill -f "Battery Trace.app/Contents/MacOS" 2>/dev/null || true
sleep 1
if [ "${SKIP_CLOSED:-0}" != 1 ]; then
  launch
  echo "Battery Trace pid $PID; warming up 60 s"
  sleep 60
  measure "popover closed" $((MINUTES * 60)) "$PID"
  stop
fi

launch -openPopover YES
sleep 10
measure "popover open" 90 "$PID"
stop

echo "Battery Trace's own ranking of the last $((MINUTES + 3)) minutes:"
sqlite3 "$DB" "SELECT a.name, printf('%.1f mWh', sum(m.cpu_j + m.gpu_j + m.ane_j) / 3.6) AS energy FROM minute_app m JOIN apps a ON a.id = m.app WHERE m.ts >= strftime('%s','now') - $(( (MINUTES + 3) * 60 )) GROUP BY a.id ORDER BY sum(m.cpu_j + m.gpu_j + m.ane_j) DESC LIMIT 12;" | nl
