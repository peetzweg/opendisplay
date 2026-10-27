#!/usr/bin/env bash
# Points the package at a new OpenDisplay release once its tag is pushed:
#   ./bump.sh 1.26.0            (or v1.26.0)
# Linux shares the app's version and `vX.Y.Z` tags (one release for every
# platform), so pkgver is the version as is; the PKGBUILD derives
# _tag=v${pkgver}. Sets pkgver and pkgrel=1, downloads the tag tarball from
# GitHub to record its sha256, and regenerates .SRCINFO. Refuses to finish
# with a SKIP checksum: the AUR must never receive one for a release tarball.
#   ./bump.sh --check-versions  checks that versions sort right under vercmp
# The same script serves opendisplay-sender and opendisplay-receiver.
set -euo pipefail
cd "$(dirname "$0")"

# 1.26.0 -> 1.26.0; v1.26.0 -> 1.26.0; anything else is refused.
pkgver_for() {
  local v="${1#v}"
  if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "bump.sh: '$1' is not X.Y.Z (an OpenDisplay release tag vX.Y.Z)" >&2
    return 1
  fi
  echo "$v"
}

check_versions() {
  local fail=0 ok a b want got
  # Each pair must sort a < b under pacman. The 0.1.0 beta pkgvers (the
  # sender's 0.1.0beta1, the receiver's 0.1.0_beta.1) are what a pre-unified
  # build may have installed; every app release must replace them.
  for pair in \
    1.25.0:1.26.0 1.26.0:1.26.1 1.9.0:1.10.0 1.26.9:1.26.10 1.99.0:2.0.0 \
    0.1.0beta1:1.26.0 0.1.0_beta.1:1.26.0; do
    a="${pair%%:*}" b="${pair##*:}"
    [[ "$a" == *beta* ]] || a=$(pkgver_for "$a")
    b=$(pkgver_for "$b")
    ok=1
    for want in "-1:$a:$b" "1:$b:$a"; do
      got=$(vercmp "$(cut -d: -f2 <<<"$want")" "$(cut -d: -f3 <<<"$want")")
      if [[ "$got" != "${want%%:*}" ]]; then
        echo "FAIL vercmp $(cut -d: -f2- <<<"$want" | tr : ' ') = $got, want ${want%%:*}" >&2
        fail=1 ok=0
      fi
    done
    [[ $ok == 1 ]] && echo "ok   $a < $b"
  done
  for bad in 1.26 1.26.0-beta.1 1.26.0beta1 linux-v0.1.0-beta.1 linux-v1.26.0 1.26.0.1 vv1.26.0; do
    if pkgver_for "$bad" >/dev/null 2>&1; then
      echo "FAIL '$bad' was accepted" >&2
      fail=1
    fi
  done
  return $fail
}

if [[ "${1:-}" == "--check-versions" ]]; then
  check_versions
  exit
fi

ver="${1:?usage: $0 <version, e.g. 1.26.0> | --check-versions}"
pkgver="$(pkgver_for "$ver")"
pkgname="$(sed -n 's/^pkgname=//p' PKGBUILD)"
sed -i -e "s/^pkgver=.*/pkgver=${pkgver}/" -e "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
# Start from SKIP so a stale sum from the previous release cannot survive a
# failed download; a tarball left by from-checkout.sh may have the same name.
sed -i "s/^sha256sums=.*/sha256sums=('SKIP')/" PKGBUILD
rm -f "${pkgname}-${pkgver}.tar.gz"
SRCDEST="${PWD}" updpkgsums
if grep -q "SKIP" PKGBUILD; then
  echo "bump.sh: PKGBUILD still has a SKIP checksum; is v${pkgver} pushed?" >&2
  exit 1
fi
makepkg --printsrcinfo > .SRCINFO
git diff --stat -- PKGBUILD .SRCINFO
