#!/usr/bin/env bash
# apt-get install for CI runners that does not hang the job on a slow mirror.
# The x86_64 runners' azure.archive.ubuntu.com mirror sometimes trickles
# (minutes per package) until the job's timeout. A normal install takes under
# a minute, so give each attempt 5 and retry (packages that already arrived
# are kept); from the second attempt on, use the primary archive instead of
# the Azure one. Needs root.
# Usage: apt-install.sh <package>...
set -euo pipefail

opts=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
for attempt in 1 2 3; do
  if [ "$attempt" -gt 1 ]; then
    echo "apt attempt $attempt: switching to the primary Ubuntu archive"
    # In case the timeout cut dpkg off mid-install rather than a download.
    dpkg --configure -a || true
    # The runners' sources point at a mirror list (mirror+file:) led by Azure.
    sed -i 's#http://azure\.archive\.ubuntu\.com#http://archive.ubuntu.com#g' \
      /etc/apt/apt-mirrors.txt /etc/apt/sources.list.d/*.sources /etc/apt/sources.list 2>/dev/null || true
  fi
  if timeout 300 apt-get "${opts[@]}" update &&
    timeout 300 apt-get "${opts[@]}" install -y --no-install-recommends "$@"; then
    exit 0
  fi
  echo "apt attempt $attempt failed or timed out" >&2
done
exit 1
