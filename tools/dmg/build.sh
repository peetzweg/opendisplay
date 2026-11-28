#!/bin/bash
# Packages a Mac app into the drag-to-Applications disk image:
#
#   tools/dmg/build.sh <path/to/App.app> <output.dmg> [volume name]
#   tools/dmg/build.sh --prepare
#
# The volume name defaults to the app's name. --prepare only installs the
# pinned dmgbuild venv; the release workflow runs it before building the apps
# so a PyPI failure stops the job before the long build and notarization.
#
# The background is rendered from layout.json on every build, so the art and
# the icon positions always agree. The release lanes in fastlane/Fastfile sign
# and notarize the result; a local image is unsigned, which is fine for
# checking the window.
#
# Environment:
#   DMGBUILD_PYTHON  interpreter for the venv (default python3; needs 3.10+)
#   DMGBUILD_VENV    venv location (default <repo>/build/dmgbuild-venv)
set -euo pipefail

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
venv=${DMGBUILD_VENV:-"$(git -C "$here" rev-parse --show-toplevel)/build/dmgbuild-venv"}
python=${DMGBUILD_PYTHON:-python3}
# Marks a venv this script created. Empty until the install succeeds, then a
# copy of the requirements it was built from.
marker="$venv/.opendisplay-dmgbuild"

die() {
  echo "error: $*" >&2
  exit 1
}

prepare_venv() {
  # Reuse the venv only if it matches the current pins and its interpreter
  # still runs: a Homebrew Python upgrade can delete the one it points to.
  if [[ -f "$marker" ]] && cmp -s "$here/requirements.txt" "$marker" \
      && "$venv/bin/python" -c 'import dmgbuild' 2>/dev/null; then
    return
  fi
  if [[ -e "$venv" && ! -f "$marker" && -n "$(ls -A "$venv" 2>/dev/null)" ]]; then
    die "$venv exists and was not created by this script; refusing to replace it"
  fi
  local version
  version=$("$python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) \
    || die "cannot run '$python'; point DMGBUILD_PYTHON at Python 3.10 or newer"
  "$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
    || die "dmgbuild needs Python 3.10 or newer, but '$python' is $version;" \
      "point DMGBUILD_PYTHON at a newer interpreter"
  rm -rf "$venv"
  "$python" -m venv "$venv"
  : > "$marker"
  "$venv/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --only-binary=:all: -r "$here/requirements.txt"
  cp "$here/requirements.txt" "$marker"
}

detach() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    hdiutil detach "$1" >/dev/null 2>&1 && return 0
    sleep "$attempt"
  done
  hdiutil detach -force "$1" >/dev/null
}

if [[ ${1:-} == --prepare ]]; then
  prepare_venv
  exit 0
fi
if [[ $# -lt 2 ]]; then
  echo "usage: $0 <path/to/App.app> <output.dmg> [volume name]" >&2
  echo "       $0 --prepare" >&2
  exit 64
fi
app=${1%/}
dmg=$2
volname=${3:-$(basename "$app" .app)}
app_name=$(basename "$app")

# The copy inside the image is checked the same way below, so start from an
# app that passes.
codesign --verify --deep --strict "$app" \
  || die "$app does not pass codesign --verify --deep --strict"

prepare_venv

work=$(mktemp -d "${TMPDIR:-/tmp}/opendisplay-dmg.XXXXXX")
mnt=$(mktemp -d "${TMPDIR:-/tmp}/opendisplay-dmg-mnt.XXXXXX")
mounted=0
cleanup() {
  if (( mounted )); then
    detach "$mnt" || true
  fi
  rmdir "$mnt" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

swift "$here/render-background.swift" "$work"

rm -f "$dmg"
# The CLI's default of 5 detach retries is too few on CI runners, where
# Spotlight and XProtect can hold a freshly mounted volume for a while.
"$venv/bin/python" -m dmgbuild --detach-retries 12 \
  -s "$here/settings.py" \
  -D app="$app" -D dir="$here" -D background="$work/background.png" \
  "$volname" "$dmg"

# dmgbuild copies the app in with ditto but ignores its exit status, so a
# failed or partial copy would still produce an image. Check the result.
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null
mounted=1
if ! codesign --verify --deep --strict "$mnt/$app_name"; then
  rm -f "$dmg"
  die "$app_name in the disk image is missing or incomplete"
fi
detach "$mnt"
mounted=0

echo "Built $dmg"
