#!/usr/bin/env bash
# Runs inside `docker run --device /dev/dri -v <checkout>:/src -v <logs>:/logs
# archlinux:latest` (linux.yml, kde-smoke): installs KWin and the build deps,
# builds od-sender and a null-sink od-receiver, then kde-smoke.sh as a user.
set -euo pipefail

pacman -Syu --noconfirm --needed \
  base-devel git rust clang pkgconf nasm ffmpeg libpipewire \
  kwin pipewire wireplumber dbus libcap
# Arch ships kwin_wayland with a file capability (CAP_SYS_NICE) that
# Docker's default set lacks, so executing it fails with "Operation not
# permitted" (as /usr/bin/sway did on #298). A plain copy carries none.
getcap /usr/bin/kwin_wayland || true
install -m755 /usr/bin/kwin_wayland /usr/local/bin/kwin_wayland
useradd --create-home tester
# Hand the checkout back afterwards: the runner's post-job cleanup has to
# write .git/config again.
owner="$(stat -c %u:%g /src)"
trap 'chown -R "$owner" /src /logs' EXIT
chown -R tester: /src /logs
# The render node (vgem on hosted runners) belongs to the host's groups.
chmod a+rw /dev/dri/* || true
ls -l /dev/dri

sudo -u tester -H bash -c '
  set -euo pipefail
  cd /src/linux
  cargo build --locked --release -p od-sender
  cargo build --locked --release -p od-receiver --no-default-features
'
sudo -u tester -H env PATH=/usr/local/bin:/usr/bin OD_RECEIVER=/src/linux/target/release/od-receiver \
  timeout 240 /src/linux/testbench/kde-smoke.sh /src/linux/target/release/od-sender /logs
