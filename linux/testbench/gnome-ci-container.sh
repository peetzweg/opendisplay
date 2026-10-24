#!/usr/bin/env bash
# Runs inside `docker run -v <checkout>:/src -v <logs>:/logs archlinux:latest`
# (linux.yml, gnome-smoke): installs Mutter and the build deps, builds
# od-sender, then gnome-smoke.sh as a user, under strace to prove that
# nothing in the stack reaches the system bus. No render node needed:
# headless Mutter renders through Mesa's surfaceless platform.
set -euo pipefail

pacman -Syu --noconfirm --needed \
  base-devel git rust clang pkgconf nasm ffmpeg libpipewire \
  mutter pipewire wireplumber dbus libcap strace
# Like sway and kwin_wayland (#298), a binary with file capabilities cannot be
# executed in Docker's default capability set; a plain copy carries none.
if [ -n "$(getcap /usr/bin/mutter)" ]; then
  getcap /usr/bin/mutter
  install -m755 /usr/bin/mutter /usr/local/bin/mutter
fi
useradd --create-home tester
# Hand the checkout back to the runner's user afterwards, or its post-job
# git cleanup cannot edit .git/config ("could not lock config file").
owner="$(stat -c %u:%g /src)"
trap 'chown -R "$owner" /src /logs' EXIT
chown -R tester: /src /logs

sudo -u tester -H bash -c '
  set -euo pipefail
  cd /src/linux
  cargo build --locked --release -p od-sender
'
rc=0
sudo -u tester -H env PATH=/usr/local/bin:/usr/bin \
  timeout 300 strace -f -qq -e trace=connect -e signal=none -o /logs/connect.trace \
  /src/linux/testbench/gnome-smoke.sh /src/linux/target/release/od-sender /logs || rc=$?
system_bus=$(grep -c /run/dbus/system_bus_socket /logs/connect.trace || true)
echo "connects to the system bus: $system_bus"
[ "$system_bus" -eq 0 ] || { echo "FAIL: the stack reached the system bus" >&2; exit 1; }
exit $rc
