#!/usr/bin/env bash
# Fails when a release binary needs a newer glibc or libstdc++ than the
# release notes promise. Only hard version needs count: a WEAK need (Rust's
# std resolves pidfd_spawnp/pidfd_getpid at run time, GLIBC_2.39) does not
# stop the binary from loading on an older glibc.
#
#   check-symbol-floor.sh <binary> [glibc-floor] [glibcxx-floor]
#
# Defaults: glibc 2.38 (Fedora 39, Ubuntu 24.04 has 2.39, Debian 13 2.41),
# libstdc++ GLIBCXX_3.4.32 (GCC 13.2, Fedora 39).
set -euo pipefail
bin="${1:?usage: $0 <binary> [glibc-floor] [glibcxx-floor]}"
glibc_floor="${2:-2.38}"
glibcxx_floor="${3:-3.4.32}"

# `readelf -V` lists each needed version as "Name: GLIBC_2.38  Flags: none".
needs="$(readelf -V --wide "$bin" | sed -n 's/.*Name: \([A-Z]*_[0-9.]*\)  *Flags: \([A-Z ]*\).*/\1 \2/p')"

newest() { # <prefix>: newest hard (non-WEAK) version for that prefix
  awk -v p="$1_" 'index($1, p) == 1 && $2 !~ /WEAK/ { print substr($1, length(p) + 1) }' <<<"$needs" |
    sort -uV | tail -1
}
newest_weak() {
  awk -v p="$1_" 'index($1, p) == 1 && $2 ~ /WEAK/ { print substr($1, length(p) + 1) }' <<<"$needs" |
    sort -uV | tail -1
}
above() { # <version> <floor>: true when version > floor
  [[ -n "$1" && "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

fail=0
glibc="$(newest GLIBC)"
glibcxx="$(newest GLIBCXX)"
echo "newest hard glibc need: GLIBC_${glibc:-none} (floor ${glibc_floor})" \
  "${newest_weak_glibc:+}$( w=$(newest_weak GLIBC); [[ -n $w ]] && echo "; weak: GLIBC_$w")"
echo "newest hard libstdc++ need: GLIBCXX_${glibcxx:-none} (floor ${glibcxx_floor})"
if above "$glibc" "$glibc_floor"; then
  echo "::error::$bin needs GLIBC_${glibc}, newer than the promised ${glibc_floor}" >&2
  objdump -T "$bin" | grep -F "(GLIBC_${glibc})" >&2 || true
  fail=1
fi
if above "$glibcxx" "$glibcxx_floor"; then
  echo "::error::$bin needs GLIBCXX_${glibcxx}, newer than the promised ${glibcxx_floor}" >&2
  objdump -T "$bin" | grep -F "(GLIBCXX_${glibcxx})" >&2 || true
  fail=1
fi
exit $fail
