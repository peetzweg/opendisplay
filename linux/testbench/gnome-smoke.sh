#!/usr/bin/env bash
# Smoke test of od-sender's GNOME backend on a headless Mutter with its own
# session bus, PipeWire and WirePlumber. Nothing touches the caller's
# session or the host's system services:
#   * XDG_RUNTIME_DIR / CONFIG / DATA / STATE / CACHE point into a temp dir;
#   * dbus-run-session gives a private session bus;
#   * DBUS_SYSTEM_BUS_ADDRESS points at a socket that does not exist, so no
#     process here can reach logind, UPower, BlueZ, NetworkManager, colord
#     or RTKit (verified with `strace -f -e connect`: zero system-bus connects);
#   * `wireplumber --profile policy` links streams but runs no device
#     monitors (no ALSA, bluez, v4l2, libcamera);
#   * gvfs is kept out (GIO_USE_VFS=local, GVFS_DISABLE_FUSE=1).
#
#   linux/testbench/gnome-smoke.sh <od-sender> [<logdir>]
#
# Needs mutter (>= 50 for explicit sizes; older sizes the monitor from the
# PipeWire format), pipewire, wireplumber, dbus-run-session.
# MUTTER_ROOT=<dir> runs a Mutter unpacked into <dir> instead of the
# installed one, e.g. on a non-GNOME machine:
#   mkdir pkgs && cd pkgs && for u in $(pacman -Sp mutter); do curl -fLO "$u" -O "$u.sig"; done
#   for f in *.pkg.tar.*[!g]; do pacman-key --verify "$f.sig" "$f" && bsdtar -xf "$f" -C "$MUTTER_ROOT"; done
#
# 1. `od-sender doctor` with XDG_CURRENT_DESKTOP=GNOME picks the gnome backend.
# 2. `dev smoke --backend gnome`: a 1170x2532 virtual monitor (no dialog),
#    PipeWire frames, x264, pointer input; afterwards the monitor is gone.
# 3. `--scale 3 --position auto-left`: snapped to 2 (what Mutter offers for
#    the mode) and placed left, through a temporary DisplayConfig change.
# 4. Crash: `kill -9` a running sender; Mutter removes its monitor itself.
set -euo pipefail

if [ -z "${OD_GNOME_INNER:-}" ]; then
  sender="$(realpath "${1:?usage: $0 <od-sender> [<logdir>]}")"
  logdir="$(realpath -m "${2:-gnome-smoke-logs}")"
  mkdir -p "$logdir"
  # Unix socket paths are limited to 108 bytes: keep the runtime dir short.
  B="$(mktemp -d "${TMPDIR:-/tmp}/odg.XXXX")"
  trap 'rm -rf "$B"' EXIT
  mkdir -p "$B"/{rt,config,data,state,cache,schemas}
  chmod 700 "$B/rt"

  R="${MUTTER_ROOT:-}"
  mutter_bin=mutter
  plugin_args=()
  if [ -n "$R" ]; then
    mutter_bin="$R/usr/bin/mutter"
    mutter_libs=("$R"/usr/lib/mutter-[0-9]*)
    LD_LIBRARY_PATH="$R/usr/lib:${mutter_libs[0]}"
    export LD_LIBRARY_PATH
    export XDG_DATA_DIRS="$R/usr/share:/usr/share"
    plugin_args=(--mutter-plugin="${mutter_libs[0]}/plugins/libdefault.so")
  fi
  cp /usr/share/glib-2.0/schemas/*.xml "$B/schemas/" 2>/dev/null || true
  [ -n "$R" ] && cp "$R"/usr/share/glib-2.0/schemas/*.xml "$B/schemas/"
  glib-compile-schemas "$B/schemas"

  env -i HOME="$HOME" PATH="$PATH" TERM="${TERM:-dumb}" \
    ${LD_LIBRARY_PATH:+LD_LIBRARY_PATH="$LD_LIBRARY_PATH"} \
    XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/share}" \
    XDG_RUNTIME_DIR="$B/rt" XDG_CONFIG_HOME="$B/config" XDG_DATA_HOME="$B/data" \
    XDG_STATE_HOME="$B/state" XDG_CACHE_HOME="$B/cache" \
    GSETTINGS_SCHEMA_DIR="$B/schemas" GSETTINGS_BACKEND=memory \
    GIO_USE_VFS=local GVFS_DISABLE_FUSE=1 \
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=$B/no-system-bus" \
    XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME \
    OD_GNOME_INNER=1 OD_SENDER="$sender" OD_LOGS="$logdir" OD_B="$B" \
    OD_MUTTER="$mutter_bin" OD_MUTTER_ARGS="${plugin_args[*]:-}" \
    dbus-run-session -- "$0"
  exit $?
fi

# Inside: private session bus, no system bus.
logs="$OD_LOGS"
cleanup() {
  local pids
  mapfile -t pids < <(jobs -p)
  [ "${#pids[@]}" -eq 0 ] || kill "${pids[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

pipewire >"$logs/pipewire.log" 2>&1 &
for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break; sleep 0.1; done
wireplumber --profile policy >"$logs/wireplumber.log" 2>&1 &
# shellcheck disable=SC2086
"$OD_MUTTER" $OD_MUTTER_ARGS --headless --wayland --no-x11 --wayland-display=wayland-od \
  --virtual-monitor 1280x800 >"$logs/mutter.log" 2>&1 &
for _ in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/wayland-od" ] && break; sleep 0.1; done
[ -S "$XDG_RUNTIME_DIR/wayland-od" ] || { echo "FAIL: mutter did not start" >&2; tail "$logs/mutter.log" >&2; exit 1; }
export WAYLAND_DISPLAY=wayland-od

fail() { echo "FAIL: $*" >&2; exit 1; }
monitors() { grep -c "Added virtual monitor" "$logs/mutter.log"; }
removed() { grep -c "Removed virtual monitor" "$logs/mutter.log" || true; }

echo "1. doctor"
"$OD_SENDER" doctor >"$logs/doctor.txt" 2>&1 || true
grep -q "=> gnome" "$logs/doctor.txt" || fail "doctor did not pick gnome (see doctor.txt)"
grep -q "GNOME Mutter (ScreenCast API" "$logs/doctor.txt" || fail "doctor could not start the gnome backend"

echo "2. dev smoke"
before=$(removed)
RUST_LOG=info "$OD_SENDER" dev smoke --backend gnome --size 1170x2532 --frames 30 --timeout 30 \
  >"$logs/smoke.log" 2>&1 || fail "smoke (see smoke.log)"
grep -q "smoke ok: 30 frames captured" "$logs/smoke.log" || fail "smoke did not capture 30 frames"
grep -q "1170x2532" "$logs/smoke.log" || fail "virtual monitor not 1170x2532"
[ "$(removed)" -gt "$before" ] || fail "virtual monitor not removed after smoke"

echo "3. scale and position"
before=$(removed)
RUST_LOG=info "$OD_SENDER" dev smoke --backend gnome --size 1170x2532 --scale 3 --position auto-left \
  --frames 5 --timeout 30 >"$logs/scale.log" 2>&1 || fail "scale smoke (see scale.log)"
# 3 is not offered for 1170x2532 (Mutter: 1, 1.5, 2): the nearest is used,
# and the monitor sits left of the headless one at 0,0.
grep -q "using 2" "$logs/scale.log" || fail "scale 3 was not snapped to 2"
grep -q "od-smoke = 1170x2532 @60 scale 2 at 0,0" "$logs/scale.log" || fail "not scale 2 at 0,0 (see scale.log)"
[ "$(removed)" -gt "$before" ] || fail "virtual monitor not removed after scale smoke"

echo "4. kill -9"
before=$(removed)
"$OD_SENDER" dev smoke --backend gnome --size 800x600 --frames 100000000 --timeout 120 \
  >"$logs/crash.log" 2>&1 &
pid=$!
sleep 2
kill -9 "$pid"
wait "$pid" 2>/dev/null || true
for _ in $(seq 30); do [ "$(removed)" -gt "$before" ] && break; sleep 0.1; done
[ "$(removed)" -gt "$before" ] || fail "Mutter kept the monitor of a killed sender"

echo "OK: gnome smoke passed ($(monitors) monitors created; logs in $logs)"
