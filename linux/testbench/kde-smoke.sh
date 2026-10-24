#!/usr/bin/env bash
# End-to-end smoke test of od-sender's KDE backend on a headless KWin
# (`kwin_wayland --virtual`), with its own D-Bus, PipeWire and WirePlumber.
# Nothing touches the caller's session: XDG_RUNTIME_DIR, XDG_CONFIG_HOME,
# XDG_DATA_HOME, XDG_STATE_HOME and XDG_CACHE_HOME all point into a temp dir.
#
#   linux/testbench/kde-smoke.sh <od-sender> [<logdir>]
#
# Needs kwin (>= 6.8, or a .desktop entry for the sender, see below),
# pipewire, wireplumber, dbus-run-session, dbus-send. OD_RECEIVER=<od-receiver>
# enables the streaming step. KWIN_ROOT=<dir> runs a KWin unpacked into <dir>
# (its usr/lib, Qt plugins and QML) instead of the installed one.
#
# KWin's virtual backend composites with OpenGL only when it finds a DRM
# render node (a GPU, or the vgem module); without one, virtual-output
# screencasts fail with "Unsupported compositing type".
#
# 1. `od-sender doctor` picks the kde backend.
# 2. `dev smoke --backend kde`: virtual output, PipeWire frames, encode;
#    while it moves the pointer (fake input), KWin's active output must be
#    the virtual one; afterwards the output is gone.
# 3. `run --backend kde` into `od-receiver --sink none`: the receiver's
#    1024x768 scale-2 hello gives a 1024x768 output at scale 2 (set through
#    kde_output_management_v2) and a 1024x768 stream.
# 4. Crash: `kill -9` a sender placed auto-left; KWin drops its output and
#    moves the user's output back by itself; `od-sender clean` then has
#    nothing to undo.
set -euo pipefail

if [ -z "${OD_KDE_INNER:-}" ]; then
  sender="$(realpath "${1:?usage: $0 <od-sender> [<logdir>]}")"
  logdir="$(realpath -m "${2:-kde-smoke-logs}")"
  mkdir -p "$logdir"
  runtime="$(mktemp -d /tmp/od-kde.XXXXXX)"
  chmod 700 "$runtime"
  mkdir -p "$runtime"/{config,data,state,cache}
  trap 'rm -rf "$runtime" 2>/dev/null || true' EXIT
  unset WAYLAND_DISPLAY DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE PIPEWIRE_REMOTE \
    QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME QT_IM_MODULE DBUS_SESSION_BUS_ADDRESS
  export XDG_RUNTIME_DIR="$runtime" XDG_CONFIG_HOME="$runtime/config" \
    XDG_DATA_HOME="$runtime/data" XDG_STATE_HOME="$runtime/state" \
    XDG_CACHE_HOME="$runtime/cache" XDG_CURRENT_DESKTOP=KDE LANG="${LANG:-C.UTF-8}" \
    GIO_USE_VFS=local GVFS_DISABLE_FUSE=1 # no gvfs FUSE mount inside $runtime
  # No system bus at all: nothing in this stack may reach BlueZ, logind,
  # NetworkManager or UPower on the host. A client that tries just fails.
  export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$runtime/no-system-bus"
  OD_KDE_INNER=1 dbus-run-session -- "$0" "$sender" "$logdir"
  exit
fi

sender="$1"
logdir="$2"
pids=()
cleanup() {
  for ((i = ${#pids[@]} - 1; i >= 0; i--)); do
    kill "${pids[i]}" 2>/dev/null || true
    wait "${pids[i]}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# KWin from KWIN_ROOT gets its libraries; od-sender never does.
kwin_env=()
if [ -n "${KWIN_ROOT:-}" ]; then
  kwin_env=(env "LD_LIBRARY_PATH=$KWIN_ROOT/usr/lib"
    "QT_PLUGIN_PATH=$KWIN_ROOT/usr/lib/qt6/plugins"
    "QML_IMPORT_PATH=$KWIN_ROOT/usr/lib/qt6/qml" "QML2_IMPORT_PATH=$KWIN_ROOT/usr/lib/qt6/qml"
    "XDG_DATA_DIRS=$KWIN_ROOT/usr/share:/usr/share" "PATH=$KWIN_ROOT/usr/bin:$PATH")
fi

# WirePlumber only links the sender's stream to KWin's node, so it runs the
# `policy` profile (0.5: no hardware.audio/bluetooth/video-capture). With the
# default `main` profile a second WirePlumber probes the real sound cards and
# registers Bluetooth profiles with BlueZ on the *system* bus.
pipewire > "$logdir/pipewire.log" 2>&1 &
pids+=($!)
sleep 0.5
wireplumber --profile policy > "$logdir/wireplumber.log" 2>&1 &
pids+=($!)
sleep 0.5
"${kwin_env[@]}" kwin_wayland --virtual --no-lockscreen --width 1280 --height 720 \
  --socket wayland-od > "$logdir/kwin.log" 2>&1 &
pids+=($!)
for _ in $(seq 100); do
  [ -S "$XDG_RUNTIME_DIR/wayland-od" ] && break
  sleep 0.1
done
[ -S "$XDG_RUNTIME_DIR/wayland-od" ] || { echo "kwin did not start"; cat "$logdir/kwin.log"; exit 1; }
export WAYLAND_DISPLAY=wayland-od
sleep 1

active() {
  dbus-send --session --print-reply --dest=org.kde.KWin /KWin org.kde.KWin.activeOutputName 2>/dev/null |
    sed -n 's/.*string "\(.*\)"/\1/p'
}
outputs() { "$sender" doctor 2>/dev/null | sed -n 's/^  output \([^ ]*\) .*/\1/p'; }

echo "--- doctor"
"$sender" doctor 2>&1 | tee "$logdir/doctor.log" || true
grep -q "=> kde" "$logdir/doctor.log" || { echo "doctor did not pick kde"; exit 1; }

echo "--- dev smoke (kde)"
"$sender" dev smoke --backend kde --size 800x600 --frames 240 --timeout 30 \
  > "$logdir/smoke.log" 2>&1 &
smoke_pid=$!
seen=
for _ in $(seq 100); do
  [ "$(active)" = "Virtual-od-smoke" ] && { seen=1; break; }
  sleep 0.05
done
wait "$smoke_pid" || { cat "$logdir/smoke.log"; echo "dev smoke failed"; exit 1; }
cat "$logdir/smoke.log"
grep -q "smoke ok" "$logdir/smoke.log" || { echo "dev smoke did not pass"; exit 1; }
[ -n "$seen" ] || { echo "the pointer never reached Virtual-od-smoke (fake input)"; exit 1; }
echo "fake input moved the pointer onto Virtual-od-smoke"
outputs | grep -x "Virtual-od-smoke" >/dev/null && { echo "Virtual-od-smoke left behind"; exit 1; }

if [ -n "${OD_RECEIVER:-}" ]; then
  port=$((20000 + RANDOM % 10000))
  "$OD_RECEIVER" --listen "127.0.0.1:$port" --sink none --no-mdns \
    --width 1024 --height 768 --scale 2 --refresh 60 --stats-every 1 \
    > "$logdir/receiver.log" 2>&1 &
  receiver_pid=$!
  pids+=("$receiver_pid")
  sleep 0.5

  echo "--- run --backend kde -> od-receiver --sink none"
  "$sender" run --to "127.0.0.1:$port" --backend kde --duration 4 > "$logdir/run.log" 2>&1 ||
    { cat "$logdir/run.log"; echo "od-sender run failed"; exit 1; }
  cat "$logdir/run.log"
  # kde_output_management_v2 sets the hello's scale (KWin alone picks one
  # from DPI) and places the output right of the existing one.
  grep -q "virtual display Virtual-od-[0-9a-f]* = 1024x768 @60 scale 2 at 1280,0" "$logdir/run.log" ||
    { echo "output not 1024x768 at scale 2, right of Virtual-0"; exit 1; }
  grep -q "streamConfig h264 1024x768" "$logdir/receiver.log" ||
    { echo "receiver saw no 1024x768 streamConfig"; exit 1; }

  echo "--- crash (during an auto-left placement) and clean"
  "$sender" run --to "127.0.0.1:$port" --backend kde --duration 30 --position auto-left \
    > "$logdir/crash.log" 2>&1 &
  run_pid=$!
  # Kill only once the placement (and the shift of Virtual-0) is applied.
  made=
  for _ in $(seq 100); do
    made="$(sed -n 's/.*virtual display \(Virtual-od-[0-9a-f]*\) = .*/\1/p' "$logdir/crash.log" | head -1)"
    [ -n "$made" ] && break
    sleep 0.1
  done
  [ -n "$made" ] || { cat "$logdir/crash.log"; echo "the sender made no output"; exit 1; }
  kill -9 "$run_pid"
  wait "$run_pid" 2>/dev/null || true
  gone=
  for _ in $(seq 30); do
    outputs | grep -x "$made" >/dev/null || { gone=1; break; }
    sleep 0.1
  done
  [ -n "$gone" ] || { echo "$made outlived its sender"; exit 1; }
  echo "KWin dropped $made with its sender"
  # KWin 6.8 moves Virtual-0 back by itself when a client dies (verified:
  # within 0.3 s). `clean` is the safety net where a KWin does not; here it
  # must find nothing to undo and leave the layout alone. (A lone offset
  # output cannot be staged: KWin and kscreen-doctor normalise it to 0,0.)
  back=
  for _ in $(seq 40); do
    layout="$("$sender" doctor 2>/dev/null || true)"
    grep -q "^  output Virtual-0 .* at 0,0$" <<< "$layout" && { back=1; break; }
    sleep 0.05
  done
  [ -n "$back" ] || { echo "$layout"; echo "Virtual-0 still shifted after the crash"; exit 1; }
  echo "KWin moved Virtual-0 back to 0,0 after the crash"
  "$sender" clean --backend kde 2>&1 | tee "$logdir/clean.log"
  grep -q "nothing to clean" "$logdir/clean.log" || { echo "clean changed an unshifted layout"; exit 1; }
  layout="$("$sender" doctor 2>/dev/null || true)"
  grep -q "^  output Virtual-0 .* at 0,0$" <<< "$layout" || { echo "$layout"; echo "clean moved Virtual-0"; exit 1; }

  echo "--- run --position auto-left"
  # KWin refuses negative positions, so the existing output moves right;
  # after the sender exits it is back at 0,0.
  "$sender" run --to "127.0.0.1:$port" --backend kde --duration 2 --position auto-left \
    > "$logdir/left.log" 2>&1 || { cat "$logdir/left.log"; echo "od-sender run failed"; exit 1; }
  cat "$logdir/left.log"
  grep -q "virtual display Virtual-od-[0-9a-f]* = 1024x768 @60 scale 2 at 0,0" "$logdir/left.log" ||
    { echo "auto-left output not at 0,0"; exit 1; }
  # The xdg-output update trails KWin's "applied" a little.
  back=
  for _ in $(seq 40); do
    # Not `doctor | grep -q`: grep exits early, doctor dies of SIGPIPE and
    # pipefail turns a match into a failure.
    layout="$("$sender" doctor 2>/dev/null || true)"
    grep -q "^  output Virtual-0 .* at 0,0$" <<< "$layout" && { back=1; break; }
    sleep 0.05
  done
  [ -n "$back" ] || { "$sender" doctor; echo "Virtual-0 not back at 0,0"; exit 1; }
  echo "Virtual-0 is back at 0,0"

else
  echo "--- OD_RECEIVER not set: skipping the streaming and crash steps"
fi

echo "kde smoke passed"
