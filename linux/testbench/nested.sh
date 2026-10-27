#!/usr/bin/env bash
# Start a nested Hyprland as a window of the current session and print the
# variables that point od-sender at it instead of the real desktop:
#
#   linux/testbench/nested.sh            # foreground; Ctrl-C stops it
#   eval "$(linux/testbench/nested.sh --env)"   # in another shell, while it runs
#
# Everything destructive (kill -9, two senders, reconfigure under capture)
# runs against this instance, never the real session.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
state="${XDG_RUNTIME_DIR:?}/od-testbench"
mkdir -p "$state"

if [[ "${1:-}" == "--env" ]]; then
    [[ -f "$state/env" ]] || { echo "no nested instance running" >&2; exit 1; }
    cat "$state/env"
    exit 0
fi

[[ -n "${WAYLAND_DISPLAY:-}" ]] || { echo "run this inside a Wayland session" >&2; exit 1; }

before="$(hyprctl -j instances | tr -d '\n ' | grep -o '"instance":"[^"]*"')"
Hyprland -c "$here/nested-hyprland.lua" >"$state/hyprland.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$state/env"' EXIT INT TERM

sig="" sock=""
for _ in $(seq 100); do
    kill -0 "$pid" 2>/dev/null || { echo "nested Hyprland exited; see $state/hyprland.log" >&2; exit 1; }
    # The new entry is whichever instance was not listed before we started.
    line="$(hyprctl -j instances | tr -d '\n ' | grep -o '{[^}]*}' | grep -vF -f <(printf '%s\n' "$before") || true)"
    if [[ -n "$line" ]]; then
        sig="$(grep -o '"instance":"[^"]*"' <<<"$line" | cut -d'"' -f4)"
        sock="$(grep -o '"wl_socket":"[^"]*"' <<<"$line" | cut -d'"' -f4)"
        break
    fi
    sleep 0.1
done
[[ -n "$sig" ]] || { echo "nested Hyprland did not register; see $state/hyprland.log" >&2; exit 1; }

printf 'export HYPRLAND_INSTANCE_SIGNATURE=%s\nexport WAYLAND_DISPLAY=%s\n' "$sig" "$sock" | tee "$state/env"
echo "nested Hyprland pid $pid; Ctrl-C to stop" >&2
wait "$pid"
