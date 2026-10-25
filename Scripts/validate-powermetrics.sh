#!/bin/bash
# Compares Battery Trace with `sudo powermetrics` under the four loads from
# the brief: idle, a CPU loop, a GPU-heavy process, and a video in Safari
# (last, so it can't leak into the others). Takes about four minutes.
#
# For each scenario it runs, at the same time:
#   powermetrics --samplers tasks,cpu_power,gpu_power --show-process-energy \
#                --show-process-coalition -i 5000 -n 3 -f plist     (as root)
#   bttrace sample --interval 5 --count 3 --json                    (as you)
# then your exact command in text form (for the record), then compares.
# Results land in validation/<date>-powermetrics/.
#
# Two ways to run it:
#   make validate-powermetrics      in a terminal; sudo asks for your password
#   as root with TARGET_USER=<you> NONINTERACTIVE=1 (e.g. from macOS's
#   administrator dialog); only powermetrics keeps root, bttrace runs as you
#   so it sees exactly what the unprivileged app sees.
set -euo pipefail
cd "$(dirname "$0")/.."
BT=$PWD/BatteryTraceKit/.build/release/bttrace
OUT=$PWD/validation/$(date +%Y%m%d-%H%M%S)-powermetrics
VIDEO=${VIDEO:-https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8}
PM=(/usr/bin/powermetrics --samplers tasks,cpu_power,gpu_power --show-process-energy --show-process-coalition -i 5000 -n 3)

if [ "$(id -u)" = 0 ]; then
  USER_NAME=${TARGET_USER:?set TARGET_USER when running as root}
  USER_ID=$(id -u "$USER_NAME")
  # In your GUI session, as you: the display and Metal need the session.
  as_user() { launchctl asuser "$USER_ID" sudo -u "$USER_NAME" -H "$@"; }
  as_root() { "$@"; }
else
  USER_NAME=$(id -un)
  as_user() { "$@"; }
  as_root() { sudo "$@"; }
  [ -x "$BT" ] || (cd BatteryTraceKit && swift build -c release --product bttrace)
  echo "powermetrics needs root; sudo will ask for your password once."
  sudo -v
  ( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
  KEEPALIVE=$!
  trap 'kill $KEEPALIVE 2>/dev/null || true' EXIT
fi
[ -x "$BT" ] || { echo "build bttrace first: make cli"; exit 1; }

pause() { # $1 message, $2 seconds to wait instead when not interactive
  if [ "${NONINTERACTIVE:-0}" = 1 ]; then echo "$1 (waiting $2 s)"; sleep "$2"; else echo "$1 Press Return."; read -r; fi
}

as_user mkdir -p "$OUT"
{ sw_vers; sysctl -n machdep.cpu.brand_string hw.model; pmset -g batt | tail -1; } > "$OUT/machine.txt"

measure() {
  local name=$1
  echo "── $name: measuring 15 s with both tools…"
  as_root "${PM[@]}" -f plist -o "$OUT/$name.plist" > /dev/null &
  local pm=$!
  as_user "$BT" sample --interval 5 --count 3 --json > "$OUT/$name.jsonl"
  wait $pm
  echo "   …and your exact command (text) for the record"
  as_root "${PM[@]}" > "$OUT/$name.txt"
  as_root chown "$USER_NAME" "$OUT/$name.plist" "$OUT/$name.txt"
  as_user "$BT" compare-powermetrics --label "$name" --ours "$OUT/$name.jsonl" --powermetrics "$OUT/$name.plist" | tee "$OUT/$name.compare.txt"
  echo
}

pause "Idle run next: leave the Mac alone." 3
measure idle

as_user "$BT" stress cpu --threads 4 --seconds 40 > /dev/null & LOAD=$!
sleep 3; measure cpu-loop; wait $LOAD 2>/dev/null || true

as_user "$BT" stress gpu --seconds 40 > /dev/null & LOAD=$!
sleep 3; measure gpu-load; wait $LOAD 2>/dev/null || true

as_user open -a Safari "$VIDEO"
pause "Safari is opening Apple's test video; it should start playing on its own." 12
measure safari-video
as_root chown -R "$USER_NAME" "$OUT"
echo "Done. Everything is in $OUT. You can close the Safari video now."
