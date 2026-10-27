#!/usr/bin/env bash
# od-receiver end to end on a headless Sway, with od-sender on the same Sway
# as the far end: no GPU, nothing touches the caller's session (own
# XDG_RUNTIME_DIR/XDG_STATE_HOME, no system bus).
#
#   linux/testbench/receiver-smoke.sh <od-sender> <od-receiver> [<logdir>]
#
# Needs sway (>= 1.10), foot, jq, a GStreamer H.264 decoder (gst-libav).
#
# 1. The receiver (gtk sink) fullscreens itself on HEADLESS-1 and announces
#    that panel in hello (panel, videoCaps).
# 2. The sender extends Sway onto a new output sized from that hello and
#    streams it; a redrawing terminal on it gives the capture damage. The
#    receiver must render at a sustained rate.
# 3. Input loop: a virtual pointer moves over the receiver's window at
#    x=0.25 / 0.75; the receiver sends touch to the sender, which moves its
#    pointer on its own output, where focus-follows-mouse must pick the
#    left / right window. That checks §6.1 normalisation end to end.
# 4. Closing: SIGINT to the receiver sends `closing`; the sender logs it.
set -euo pipefail

sender="$(realpath "${1:?usage: $0 <od-sender> <od-receiver> [<logdir>]}")"
receiver="$(realpath "${2:?usage: $0 <od-sender> <od-receiver> [<logdir>]}")"
logdir="$(realpath -m "${3:-receiver-smoke-logs}")"
mkdir -p "$logdir"

runtime="$(mktemp -d /tmp/od-rx.XXXXXX)"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime" XDG_STATE_HOME="$runtime/state"
unset WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE DISPLAY DBUS_SESSION_BUS_ADDRESS \
  QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME GDK_BACKEND GDK_SCALE
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$runtime/no-system-bus"
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
export LANG="${LANG:-C.UTF-8}" GIO_USE_VFS=local GVFS_DISABLE_FUSE=1
# GTK without a session bus or settings daemon: no a11y bus, no portal.
export NO_AT_BRIDGE=1 GTK_A11Y=none GDK_DEBUG="${GDK_DEBUG:-}"

cat > "$runtime/sway.conf" <<'EOF'
xwayland disable
default_border none
focus_follows_mouse yes
output HEADLESS-1 mode 1280x720@60Hz
EOF

pids=()
cleanup() {
  for ((i = ${#pids[@]} - 1; i >= 0; i--)); do
    kill "${pids[i]}" 2>/dev/null || true
    wait "${pids[i]}" 2>/dev/null || true
  done
  rm -rf "$runtime" 2>/dev/null || true
}
trap cleanup EXIT

sway -c "$runtime/sway.conf" > "$logdir/sway.log" 2>&1 &
pids+=($!)
sock=
for _ in $(seq 50); do
  sock="$(ls "$runtime"/sway-ipc.*.sock 2>/dev/null || true)"
  [ -n "$sock" ] && [ -S "$runtime/wayland-1" ] && break
  sleep 0.1
done
[ -n "$sock" ] || { echo "sway did not start"; cat "$logdir/sway.log"; exit 1; }
export SWAYSOCK="$sock" WAYLAND_DISPLAY=wayland-1
outputs() { swaymsg -t get_outputs -r | jq -r '.[].name' | sort; }
focused() { swaymsg -t get_tree -r | jq -r '.. | select(.focused? == true) | .app_id // .name'; }

echo "--- receiver on HEADLESS-1"
port=$((20000 + RANDOM % 10000))
RUST_LOG="${RX_LOG:-info}" "$receiver" --listen "127.0.0.1:$port" --no-mdns --output HEADLESS-1 \
  --stats-every 1 > "$logdir/receiver.log" 2>&1 &
receiver_pid=$!
pids+=("$receiver_pid")
up=
for _ in $(seq 100); do
  grep -q "listening on" "$logdir/receiver.log" && { up=1; break; }
  sleep 0.1
done
[ -n "$up" ] || { cat "$logdir/receiver.log"; echo "receiver did not start"; exit 1; }
grep "listening on\|monitor HEADLESS" "$logdir/receiver.log" || true
# The receiver's window is fullscreen on HEADLESS-1.
rxwin() {
  swaymsg -t get_tree -r |
    jq -c '.. | select((.app_id? // "") | test("^app.opendisplay.Receiver$")) | {app_id, fullscreen_mode, rect}'
}
for _ in $(seq 50); do
  [ "$(rxwin | jq -r '.fullscreen_mode')" = 1 ] && break
  sleep 0.1
done
echo "receiver window: $(rxwin)"
[ "$(rxwin | jq -r '.fullscreen_mode')" = 1 ] || { echo "receiver window is not fullscreen"; exit 1; }

echo "--- sender -> receiver"
before="$(outputs)"
RUST_LOG=info "$sender" run --to "127.0.0.1:$port" --backend wlroots --duration 12 \
  > "$logdir/sender.log" 2>&1 &
sender_pid=$!
pids+=("$sender_pid")
made=
for _ in $(seq 100); do
  made="$(comm -13 <(echo "$before") <(outputs))"
  [ -n "$made" ] && break
  sleep 0.1
done
[ -n "$made" ] || { cat "$logdir/sender.log"; echo "the sender made no output"; exit 1; }
echo "sender output: $made"
# Two windows on the sender's output, the left one redrawing constantly.
windows() { swaymsg -t get_tree -r | jq -r '.. | select(.app_id? == "left" or .app_id? == "right") | .app_id'; }
swaymsg -q focus output "$made"
spawn() {
  swaymsg -q "exec foot -c /dev/null --app-id $1 -- sh -c '$2'"
  for _ in $(seq 50); do
    windows | grep -x "$1" >/dev/null && return
    sleep 0.1
  done
  echo "foot window $1 did not map"; exit 1
}
spawn left 'while :; do date +%s.%N; sleep 0.005; done'
spawn right 'sleep 600'
sleep 3

best="$(grep -o '"renderFps":[0-9.]*' "$logdir/receiver.log" | cut -d: -f2 | sort -n | tail -1)"
echo "receiver: best renderFps ${best:-0}"
awk -v f="${best:-0}" 'BEGIN { exit !(f >= 15) }' || { echo "receiver renderFps ${best:-0} < 15"; exit 1; }
"$sender" dev capture-test --output HEADLESS-1 --seconds 0.5 --save "$logdir/receiver-screen.ppm" \
  > "$logdir/capture.log" 2>&1 || true

echo "--- input: receiver window -> sender"
# Warm-up: Sway ignores the first motion for focus.
"$sender" dev input-test --output HEADLESS-1 --x 0.5 --y 0.9 --hold 0.3 >> "$logdir/input.log" 2>&1
for step in "0.25 left" "0.75 right" "0.25 left"; do
  read -r x want <<< "$step"
  "$sender" dev input-test --output HEADLESS-1 --x "$x" --y 0.5 --hold 0.5 >> "$logdir/input.log" 2>&1
  sleep 0.3
  got="$(focused)"
  echo "pointer over the receiver at x=$x: sender focused $got"
  [ "$got" = "$want" ] || { echo "expected $want focused"; exit 1; }
done
grep -o '"input_events": *[0-9]*\|input_events: [0-9]*' "$logdir/receiver.log" | tail -1 || true

echo "--- closing"
kill -INT "$receiver_pid"
wait "$receiver_pid" || true
for _ in $(seq 30); do
  grep -qiE "closed the session|closing" "$logdir/sender.log" && break
  sleep 0.1
done
grep -iE "closed the session|closing" "$logdir/sender.log" | head -2 ||
  { echo "the sender never heard the receiver close"; exit 1; }
echo "receiver smoke passed: renderFps $best"
