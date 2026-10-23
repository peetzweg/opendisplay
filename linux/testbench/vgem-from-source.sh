#!/usr/bin/env bash
# Build and load vgem for the running kernel when the distro ships none.
# Some GitHub runner images (ubuntu-24.04 20261012, 6.17.0-1022-azure) have
# no vgem module, not even in linux-modules-extra. vgem is two small files;
# build them out of tree against the installed headers. Needs root.
set -euo pipefail

rel=$(uname -r)
build=/lib/modules/$rel/build
[ -d "$build" ] || apt-get install -y --no-install-recommends "linux-headers-$rel"

# Upstream tag for the kernel's base version: 6.17.0-1022-azure -> v6.17.
base=$(echo "$rel" | grep -oE '^[0-9]+\.[0-9]+')
src=$(mktemp -d)
# raw.githubusercontent.com rate-limits runner IPs (429), so kernel.org first.
for f in vgem_drv.c vgem_drv.h vgem_fence.c; do
  curl -fsSL --retry 3 -o "$src/$f" \
    "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/gpu/drm/vgem/$f?h=v$base" ||
    curl -fsSL --retry 3 -o "$src/$f" \
      "https://raw.githubusercontent.com/torvalds/linux/v$base/drivers/gpu/drm/vgem/$f"
done
cat > "$src/Kbuild" <<'EOF'
obj-m := vgem.o
vgem-y := vgem_drv.o vgem_fence.o
EOF

# Build with the compiler the kernel was built with (e.g. gcc-14), or the
# module may be rejected or fail to build.
cc=gcc
ver=$(grep -oE 'CONFIG_CC_VERSION_TEXT="[^ ]+ [^ ]+ [0-9]+' "$build/.config" | grep -oE '[0-9]+$' || true)
if [ -n "$ver" ]; then
  command -v "gcc-$ver" >/dev/null || apt-get install -y --no-install-recommends "gcc-$ver"
  cc=gcc-$ver
fi

make -C "$build" M="$src" CC="$cc" modules
# vgem's dependencies (drm, drm_shmem_helper) are in-distro modules.
modprobe drm_shmem_helper || true
insmod "$src/vgem.ko"
