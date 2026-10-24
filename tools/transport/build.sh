#!/bin/zsh
# Build nettest for this Mac and the receiver (x86_64 + arm64 targets, macOS 13),
# make a throwaway TLS identity for QUIC, and copy everything to the receiver.
# env: OD_RECEIVER_HOST (default imac)
set -e
ROOT=${0:A:h:h:h}; B=$ROOT/build/transport; R=${OD_RECEIVER_HOST:-imac}
mkdir -p $B && cd $B
if [[ ! -f nettest.p12 ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 3650 -subj "/CN=nettest" 2>/dev/null
  # 3DES/SHA1 so SecPKCS12Import on older macOS accepts it
  openssl pkcs12 -export -inkey k.pem -in c.pem -out nettest.p12 -passout pass:nettest \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
fi
swiftc -O -target arm64-apple-macos13 $ROOT/tools/transport/nettest.swift -o nettest
swiftc -O -target x86_64-apple-macos13 $ROOT/tools/transport/nettest.swift -o nettest-x86
arch=$(ssh -n $R uname -m)
ssh -n $R 'mkdir -p /tmp/nettest'
scp -q $([[ $arch == arm64 ]] && echo nettest || echo nettest-x86) $R:/tmp/nettest/nettest
scp -q nettest.p12 $ROOT/tools/transport/probe.py $R:/tmp/nettest/
echo "built into $B and $R:/tmp/nettest"
