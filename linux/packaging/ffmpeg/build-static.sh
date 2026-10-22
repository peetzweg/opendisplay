#!/usr/bin/env bash
# Builds the minimal static FFmpeg (plus static x264) that release tarballs of
# od-sender link, so the binary needs nothing beyond glibc, libgcc and
# libstdc++ and runs on any distribution regardless of its FFmpeg soname.
# The AUR package keeps linking the system FFmpeg.
#
#   linux/packaging/ffmpeg/build-static.sh <prefix>
#   FFMPEG_DIR=<prefix> RUSTFLAGS="$(cat <prefix>/rustflags)" \
#     cargo build --release -p od-sender
#
# Only what od-sender uses is enabled: the libx264 and h264_v4l2m2m encoders,
# swscale, and the avformat library (ffmpeg-next will not build without it;
# no muxers or protocols). Autodetection is off so no system library sneaks
# into the link. FFMPEG_VAAPI=1 adds h264_vaapi, which links libva/libdrm
# dynamically (for a later x86 VA-API encoder; unused today).
#
# Inputs are pinned by commit and the CI cache is keyed on this file's hash,
# so bumping a version below rebuilds everywhere.
set -euo pipefail

FFMPEG_TAG=n9.0.2
FFMPEG_COMMIT=946fcce07b6dcd0331c8cc609192aeff5e1924f8
X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55  # stable, r3222 (libx264 165)

prefix="$(realpath -m "${1:?usage: $0 <install prefix>}")"
work="${prefix}.build"
jobs="$(nproc)"
rm -rf "${work}" "${prefix}"
mkdir -p "${work}" "${prefix}"

fetch() {  # fetch <url> <commit> <dir> [ref]
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "${4:-$2}"
  git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD
  local got
  got="$(git -C "$3" rev-parse HEAD)"
  [ "${got}" = "$2" ] || { echo "$1: expected $2, got ${got}" >&2; exit 1; }
}

fetch https://code.videolan.org/videolan/x264.git "${X264_COMMIT}" "${work}/x264"
fetch https://github.com/FFmpeg/FFmpeg.git "${FFMPEG_COMMIT}" "${work}/ffmpeg" "refs/tags/${FFMPEG_TAG}"

(
  cd "${work}/x264"
  ./configure --prefix="${prefix}" --enable-static --enable-pic \
    --disable-cli --disable-opencl --disable-lavf --disable-swscale \
    --disable-ffms --disable-gpac --disable-lsmash
  make -j"${jobs}"
  make install-lib-static
)

encoders=libx264,h264_v4l2m2m
extra=()
if [ "${FFMPEG_VAAPI:-0}" = 1 ]; then
  encoders="${encoders},h264_vaapi"
  extra+=(--enable-vaapi --enable-libdrm)
fi

(
  cd "${work}/ffmpeg"
  PKG_CONFIG_PATH="${prefix}/lib/pkgconfig" ./configure \
    --prefix="${prefix}" \
    --pkg-config-flags=--static \
    --enable-static --disable-shared --enable-pic \
    --disable-autodetect --disable-everything \
    --disable-programs --disable-doc --disable-network \
    --disable-avdevice --disable-avfilter --disable-swresample \
    --enable-gpl --enable-libx264 --enable-v4l2-m2m \
    --enable-encoder="${encoders}" \
    "${extra[@]}"
  make -j"${jobs}"
  make install
)

# Static archives carry no dependency list, and ffmpeg-sys-next names the
# FFmpeg libraries in an order that suits shared objects (avutil before
# swscale). So the final link gets every archive again, in dependency order
# inside one group, plus x264's system libraries. Trailing link-args land after
# all of rustc's own libraries, where GNU ld resolves what is still missing.
{
  printf -- '-C link-arg=%s ' -Wl,--start-group
  for lib in avformat avcodec swscale avutil x264; do
    printf -- '-C link-arg=%s ' "${prefix}/lib/lib${lib}.a"
  done
  # -lgcc: GCC's aarch64 outline-atomics helpers (__aarch64_ldadd4_sync…)
  # live only in libgcc.a, which rustc's -nodefaultlibs link leaves out.
  printf -- '-C link-arg=%s ' -Wl,--end-group -lpthread -lm -ldl -lgcc
  if [ "${FFMPEG_VAAPI:-0}" = 1 ]; then
    printf -- '-C link-arg=%s ' -lva -lva-drm -ldrm
  fi
  echo
} > "${prefix}/rustflags"

# Licence texts ride the cache with the libraries; the release tarball's
# THIRD-PARTY-LICENSES.txt is built from them.
install -Dm644 "${work}/x264/COPYING" "${prefix}/share/licenses/x264/COPYING"
install -Dm644 "${work}/ffmpeg/LICENSE.md" "${prefix}/share/licenses/ffmpeg/LICENSE.md"
for f in COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3; do
  if [ -f "${work}/ffmpeg/${f}" ]; then
    install -Dm644 "${work}/ffmpeg/${f}" "${prefix}/share/licenses/ffmpeg/${f}"
  fi
done

rm -rf "${work}"
echo "static FFmpeg ${FFMPEG_TAG} + x264 ${X264_COMMIT:0:7} in ${prefix}"
ls -l "${prefix}/lib"
