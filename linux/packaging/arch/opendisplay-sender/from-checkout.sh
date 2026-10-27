#!/usr/bin/env bash
# Builds the package from this checkout's HEAD instead of the release tag:
# `git archive` stands in for GitHub's tag tarball (same top-level directory).
# The version comes from the checkout, not from the PKGBUILD (which names the
# last release bump.sh pointed it at):
#   on the release tag v1.26.0           -> pkgver 1.26.0
#   5 commits past it                    -> pkgver 1.26.0.r5.gabc1234
#   no tag in reach (a shallow clone)    -> <workspace version>.r0.gabc1234
# Commit first; the worktree is not included.
# Extra arguments go to makepkg, e.g. `./from-checkout.sh -si` (build and
# install) or `./from-checkout.sh --nocheck`.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source-path=SCRIPTDIR
source PKGBUILD
top="$(git rev-parse --show-toplevel)"
if desc="$(git describe --tags --long --match 'v[0-9]*' HEAD 2>/dev/null)"; then
  base="${desc%-*-g*}"                  # v1.26.0-5-gabc1234 -> v1.26.0
  rest="${desc#"${base}-"}"             # 5-gabc1234
  base="${base#v}"
  if [[ "${rest%%-*}" == 0 ]]; then
    ver="$base"
  else
    ver="${base}.r${rest%%-*}.${rest#*-}"
  fi
else
  ws="$(sed -n '/^\[workspace\.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' "${top}/linux/Cargo.toml")"
  ver="${ws}.r0.g$(git rev-parse --short HEAD)"
fi
echo "from-checkout.sh: building ${pkgname} ${ver}"
tarball="${pkgname}-${ver}.tar.gz"
git -C "$top" archive --format=tar.gz --prefix="opendisplay-${ver}/" -o "${PWD}/${tarball}" HEAD
# The PKGBUILD with this version; the local tarball is not the tag's, so its
# checksum cannot match.
trap 'rm -f .PKGBUILD.checkout' EXIT
sed "s/^pkgver=.*/pkgver=${ver}/" PKGBUILD > .PKGBUILD.checkout
SRCDEST="${PWD}" makepkg -p .PKGBUILD.checkout --force --cleanbuild --skipchecksums "$@"
