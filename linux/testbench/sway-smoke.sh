#!/usr/bin/env bash
# End-to-end smoke test of od-sender on a headless Sway: no GPU, no
# Hyprland, nothing touches the caller's session (own XDG_RUNTIME_DIR, so the
# sender can only reach this Sway). Used by CI (linux.yml, arch-package) and
# runnable locally:
#
#   linux/testbench/sway-smoke.sh <od-sender> [<logdir>]
#
# Needs sway (>= 1.10 for ext-image-copy-capture), foot, wlr-randr, jq; and
# for the streaming steps OD_RECEIVER=<od-receiver> (built with or without
# GStreamer; it runs with --sink none). Without it those steps are skipped.
#
# 1. Create an output with `swaymsg create_output`, size it through
#    zwlr_output_manager_v1 (wlr-randr --custom-mode), as the wlroots backend
#    sizes its own.
# 2. Two foot windows on it, the left one redrawing constantly (capture only
#    yields frames on damage).
# 3. `od-sender doctor`, for the log: what the sender makes of this desktop.
# 4. `od-sender dev smoke --backend adopt --output`: the sender's own
#    backend path (adopt, capture, input, encode, teardown) on that output.
# 5. `od-sender dev capture-test`: at least MIN_FRAMES frames and a saved
#    frame of the right size.
# 6. `od-sender dev input-test --output`: the virtual pointer, bound to that
#    output, moves to x=0.25 then 0.75; Sway's focus-follows-mouse must move
#    focus to the left then right window, which proves absolute motion lands
#    on the right output at the right place (dev smoke cannot check that).
# 7. `od-sender dev smoke --backend wlroots`: the backend creates, sizes,
#    captures and removes its own output.
#    With `--workspace 8`, workspace 8 must be visible on that output while
#    the user's focused workspace stays focused.
# 8. `od-sender run --backend wlroots` against `od-receiver --sink none`: the
#    receiver's hello sizes the output (scale 2), the redrawing window is
#    moved onto it, and the receiver must report the stream config and a
#    sustained frame rate; the output is gone after the sender exits.
# 9. Crash: `kill -9` a running sender; its output stays, recorded, and
#    `od-sender clean` removes it.
set -euo pipefail

sender="$(realpath "${1:?usage: $0 <od-sender> [<logdir>]}")"
logdir="$(realpath -m "${2:-sway-smoke-logs}")"
MIN_FRAMES="${MIN_FRAMES:-30}"
mkdir -p "$logdir"

# Short path: Wayland and Sway IPC socket paths are limited to 108 bytes.
runtime="$(mktemp -d /tmp/od-sway.XXXXXX)"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
# od-receiver persists its id under XDG_STATE_HOME; keep it out of $HOME.
export XDG_STATE_HOME="$runtime/state"
unset WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE DISPLAY DBUS_SESSION_BUS_ADDRESS
# No system bus: nothing here may reach logind, BlueZ or NetworkManager on
# the host (headless wlroots needs no seat). A client that tries just fails.
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$runtime/no-system-bus"
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
export LANG="${LANG:-C.UTF-8}"

cat > "$runtime/sway.conf" <<'EOF'
xwayland disable
default_border none
focus_follows_mouse yes
EOF

sway_pid=
cleanup() {
  [ -n "$sway_pid" ] && kill "$sway_pid" 2>/dev/null && wait "$sway_pid" 2>/dev/null
  rm -rf "$runtime"
}
trap cleanup EXIT

sway -c "$runtime/sway.conf" > "$logdir/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 50); do
  sock="$(ls "$runtime"/sway-ipc.*.sock 2>/dev/null || true)"
  [ -n "$sock" ] && [ -S "$runtime/wayland-1" ] && break
  sleep 0.1
done
[ -n "$sock" ] || { echo "sway did not start"; cat "$logdir/sway.log"; exit 1; }
export SWAYSOCK="$sock" WAYLAND_DISPLAY=wayland-1
swaymsg -t get_version -r | jq -r '"sway " + .human_readable'

outputs() { swaymsg -t get_outputs -r | jq -r '.[].name' | sort; }
before="$(outputs)"
swaymsg -q create_output
out="$(comm -13 <(echo "$before") <(outputs))"
[ -n "$out" ] || { echo "create_output made no output"; exit 1; }
wlr-randr --output "$out" --custom-mode 640x480@60Hz
mode="$(swaymsg -t get_outputs -r | jq -r --arg o "$out" '.[] | select(.name == $o) | .current_mode | "\(.width)x\(.height)@\(.refresh)"')"
echo "output $out: $mode"
[ "$mode" = "640x480@60000" ] || { echo "custom mode not applied"; exit 1; }

swaymsg -q focus output "$out"
windows() { swaymsg -t get_tree -r | jq -r '.. | select(.app_id? == "left" or .app_id? == "right") | .app_id'; }
# One at a time: Sway tiles in map order, and the left window must be left.
spawn() {  # spawn <app-id> <command>
  swaymsg -q "exec foot -c /dev/null --app-id $1 -- sh -c '$2'"
  for _ in $(seq 50); do
    windows | grep -x "$1" >/dev/null && return
    sleep 0.1
  done
  echo "foot window $1 did not map"; exit 1
}
spawn left 'while :; do date +%s.%N; sleep 0.005; done'
spawn right 'sleep 600'
focused() { swaymsg -t get_tree -r | jq -r '.. | select(.focused? == true) | .app_id // .name'; }

echo "--- doctor"
"$sender" doctor 2>&1 | tee "$logdir/doctor.log" || true

echo "--- dev smoke (adopt)"
"$sender" dev smoke --backend adopt --output "$out" --size 640x480 --frames 30 2>&1 |
  tee "$logdir/smoke.log"
grep -q "smoke ok" "$logdir/smoke.log" || { echo "dev smoke did not pass"; exit 1; }

echo "--- capture"
"$sender" dev capture-test --output "$out" --seconds 3 --save "$logdir/frame.ppm" 2>&1 |
  tee "$logdir/capture.log"
frames="$(sed -n 's/.* \([0-9]\+\) frames captured.*/\1/p' "$logdir/capture.log")"
[ "${frames:-0}" -ge "$MIN_FRAMES" ] || { echo "captured ${frames:-0} frames, want >= $MIN_FRAMES"; exit 1; }
header="$(head -c 15 "$logdir/frame.ppm" | tr '\n' ' ')"
case "$header" in "P6 640 480 "*) ;; *) echo "saved frame header: $header"; exit 1 ;; esac

echo "--- input"
# Sway ignores the first pointer motion after it starts for focus purposes
# (it only seeds the cursor position; later motions from fresh virtual
# pointers do move focus), so warm up once without checking.
"$sender" dev input-test --output "$out" --x 0.5 --y 0.9 --hold 0.3 2>&1 | tee -a "$logdir/input.log"
for step in "0.25 left" "0.75 right" "0.25 left"; do
  read -r x want <<< "$step"
  "$sender" dev input-test --output "$out" --x "$x" --y 0.5 --hold 0.3 2>&1 | tee -a "$logdir/input.log"
  got="$(focused)"
  echo "pointer at x=$x: focused $got"
  [ "$got" = "$want" ] || { echo "expected $want focused"; exit 1; }
done

echo "--- dev smoke (wlroots)"
before="$(outputs)"
"$sender" dev smoke --backend wlroots --size 800x600 --frames 30 2>&1 |
  tee "$logdir/smoke-wlroots.log"
grep -q "smoke ok" "$logdir/smoke-wlroots.log" || { echo "wlroots dev smoke did not pass"; exit 1; }
[ "$(outputs)" = "$before" ] || { echo "dev smoke left an output behind"; exit 1; }

echo "--- workspace"
# --workspace: workspace 8 lands on the sender's output and is visible there,
# while the user's focused workspace stays focused.
focused_ws() { swaymsg -t get_workspaces -r | jq -r '.[] | select(.focused) | .name'; }
user_ws="$(focused_ws)"
"$sender" dev smoke --backend wlroots --size 800x600 --frames 5 --workspace 8 --hold 3 \
  >"$logdir/smoke-workspace.log" 2>&1 &
ws_pid=$!
ws_out=""
for _ in $(seq 40); do
  ws_out="$(swaymsg -t get_workspaces -r | jq -r '.[] | select(.name == "8" and .visible) | .output')"
  [ -n "$ws_out" ] && break
  sleep 0.1
done
wait "$ws_pid" || { cat "$logdir/smoke-workspace.log"; echo "workspace smoke failed"; exit 1; }
[ -n "$ws_out" ] && [ "$ws_out" != "$out" ] || { echo "workspace 8 not shown on the sender's output (got '$ws_out')"; exit 1; }
[ "$(focused_ws)" = "$user_ws" ] || { echo "focus moved from $user_ws to $(focused_ws)"; exit 1; }
echo "workspace 8 shown on $ws_out; focus stayed on $user_ws"

if [ -n "${OD_RECEIVER:-}" ]; then
  port=$((20000 + RANDOM % 10000))
  receiver_pid=
  start_receiver() {
    "$OD_RECEIVER" --listen "127.0.0.1:$port" --sink none --no-mdns \
      --width 1024 --height 768 --scale 2 --refresh 60 --stats-every 1 \
      >> "$logdir/receiver.log" 2>&1 &
    receiver_pid=$!
    sleep 0.5
  }
  stop_receiver() { kill -INT "$receiver_pid" 2>/dev/null; wait "$receiver_pid" 2>/dev/null || true; }
  new_output() {  # new_output <outputs before>: wait for exactly one more
    for _ in $(seq 100); do
      local n
      n="$(comm -13 <(echo "$1") <(outputs))"
      [ -n "$n" ] && { echo "$n"; return; }
      sleep 0.1
    done
  }

  echo "--- run --backend wlroots -> od-receiver --sink none"
  start_receiver
  before="$(outputs)"
  "$sender" run --to "127.0.0.1:$port" --backend wlroots --duration 6 > "$logdir/run.log" 2>&1 &
  run_pid=$!
  made="$(new_output "$before")"
  [ -n "$made" ] || { echo "the sender made no output"; cat "$logdir/run.log"; exit 1; }
  # Damage for the capture: the redrawing terminal moves onto it.
  swaymsg -q "[app_id=left] move container to output $made"
  wait "$run_pid" || { echo "od-sender run failed"; cat "$logdir/run.log"; exit 1; }
  stop_receiver
  cat "$logdir/run.log"
  mode="$(grep -o 'virtual display [^ ]* = [0-9x]* @[0-9]* scale [0-9.]*' "$logdir/run.log" | head -1)"
  echo "sender: $mode"
  case "$mode" in *"= 1024x768 @60 scale 2") ;; *) echo "output not sized from hello"; exit 1 ;; esac
  grep -q "streamConfig h264 1024x768" "$logdir/receiver.log" || { echo "receiver saw no streamConfig"; exit 1; }
  best="$(grep -o '"fps":[0-9.]*' "$logdir/receiver.log" | cut -d: -f2 | sort -n | tail -1)"
  echo "receiver: best fps ${best:-0}"
  awk -v f="${best:-0}" 'BEGIN { exit !(f >= 20) }' || { echo "receiver fps ${best:-0} < 20"; exit 1; }
  outputs | grep -x "$made" >/dev/null && { echo "$made still present after the sender exited"; exit 1; }

  echo "--- crash and clean"
  start_receiver
  before="$(outputs)"
  "$sender" run --to "127.0.0.1:$port" --backend wlroots --duration 30 > "$logdir/crash.log" 2>&1 &
  run_pid=$!
  made="$(new_output "$before")"
  [ -n "$made" ] || { echo "the sender made no output"; cat "$logdir/crash.log"; exit 1; }
  sleep 1
  kill -9 "$run_pid"
  wait "$run_pid" 2>/dev/null || true
  stop_receiver
  outputs | grep -x "$made" >/dev/null || { echo "$made vanished with the sender"; exit 1; }
  "$sender" doctor 2>&1 | grep -- "-> $made" || { echo "doctor does not list $made"; exit 1; }
  "$sender" clean --backend wlroots 2>&1 | tee "$logdir/clean.log"
  outputs | grep -x "$made" >/dev/null && { echo "clean left $made"; exit 1; }
else
  echo "--- OD_RECEIVER not set: skipping the streaming and crash steps"
fi

echo "--- teardown"
swaymsg -q output "$out" unplug
outputs | grep -x "$out" >/dev/null && { echo "$out still present after unplug"; exit 1; }
kill -0 "$sway_pid" || { echo "sway exited"; exit 1; }
echo "sway smoke passed: $frames frames, input on $out"
