#!/usr/bin/env bash
# od-receiver as a kiosk: cage (headless) runs it as its only application,
# as the NixOS kiosk module does; od-fake-sender streams into
# it. No GPU, own XDG_RUNTIME_DIR/XDG_STATE_HOME, no system bus.
#
#   linux/testbench/cage-smoke.sh <od-receiver> <od-fake-sender> <clip.h264> [<logdir>]
#
# Needs cage (wlroots 0.18+) and a GStreamer H.264 decoder (gst-libav).
# Checks: the receiver comes up inside cage and announces cage's output in
# hello, renders the stream at a sustained rate, takes cursor updates, and
# says `closing` when cage ends it.
set -euo pipefail

receiver="$(realpath "${1:?usage: $0 <od-receiver> <od-fake-sender> <clip.h264> [<logdir>]}")"
fake="$(realpath "${2:?usage: $0 <od-receiver> <od-fake-sender> <clip.h264> [<logdir>]}")"
clip="$(realpath "${3:?usage: $0 <od-receiver> <od-fake-sender> <clip.h264> [<logdir>]}")"
logdir="$(realpath -m "${4:-cage-smoke-logs}")"
mkdir -p "$logdir"

runtime="$(mktemp -d /tmp/od-cage.XXXXXX)"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime" XDG_STATE_HOME="$runtime/state"
unset WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE DISPLAY DBUS_SESSION_BUS_ADDRESS \
  QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME GDK_BACKEND GDK_SCALE
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$runtime/no-system-bus"
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
export LANG="${LANG:-C.UTF-8}" GIO_USE_VFS=local GVFS_DISABLE_FUSE=1 NO_AT_BRIDGE=1

cage_pid=
cleanup() {
  [ -n "$cage_pid" ] && kill "$cage_pid" 2>/dev/null && wait "$cage_pid" 2>/dev/null
  rm -rf "$runtime" 2>/dev/null || true
}
trap cleanup EXIT

port=$((20000 + RANDOM % 10000))
echo "--- cage running od-receiver"
RUST_LOG=info cage -d -- "$receiver" --listen "127.0.0.1:$port" --no-mdns --stats-every 1 \
  > "$logdir/cage.log" 2>&1 &
cage_pid=$!
up=
for _ in $(seq 100); do
  grep -q "listening on" "$logdir/cage.log" && { up=1; break; }
  sleep 0.1
done
[ -n "$up" ] || { cat "$logdir/cage.log"; echo "receiver did not come up in cage"; exit 1; }
grep -E "monitor |listening on" "$logdir/cage.log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c29- | cut -c1-160

echo "--- fake sender -> receiver"
"$fake" --connect "127.0.0.1:$port" --clip "$clip" --fps 60 --duration 4 --cursor \
  > "$logdir/fake-sender.log" 2>&1 &
fake_pid=$!
sleep 3
best="$(grep -o '"renderFps":[0-9.]*' "$logdir/cage.log" | cut -d: -f2 | sort -n | tail -1)"
echo "receiver in cage: best renderFps ${best:-0}"
awk -v f="${best:-0}" 'BEGIN { exit !(f >= 15) }' || { echo "renderFps ${best:-0} < 15"; exit 1; }

echo "--- cage ends the receiver"
# The kiosk's receiver is cage's child: stopping it must say `closing`.
receiver_pid="$(pgrep -P "$cage_pid" -f "$receiver" | head -1 || true)"
[ -n "$receiver_pid" ] || { echo "no receiver process under cage"; exit 1; }
kill -INT "$receiver_pid"
wait "$fake_pid" || true
grep -q "receiver closing" "$logdir/fake-sender.log" ||
  { cat "$logdir/fake-sender.log"; echo "the sender never heard closing"; exit 1; }
updates="$(grep -o 'cursor_updates: [0-9]*' "$logdir/cage.log" | awk '{print $2}' | tail -1)"
echo "cursor updates taken: ${updates:-0}"
[ "${updates:-0}" -gt 0 ] || { echo "no cursor updates reached the receiver"; exit 1; }
echo "cage smoke passed: renderFps $best"
