#!/bin/bash
# Build pinned static libraries for the same deployment target as the installer.
set -euo pipefail
prefix="$PWD/build/dependencies"
sources="$PWD/build/dependency-sources"
helper="$PWD"
mkdir -p "$prefix" "$sources"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS='-O2 -mmacosx-version-min=14.0'
export CXXFLAGS="$CFLAGS"
export LDFLAGS='-mmacosx-version-min=14.0'
cd "$sources"
curl --fail --location --retry 3 -o libplist.tar.bz2 https://github.com/libimobiledevice/libplist/releases/download/2.8.0/libplist-2.8.0.tar.bz2
echo 'b1f59f7634c58b2481325a23ff4e3bf51574a42d868cbe466d2b39b04550752a  libplist.tar.bz2' | shasum -a 256 -c -
tar -xf libplist.tar.bz2
cd libplist-2.8.0
./configure --prefix="$prefix" --enable-static --disable-shared --without-cython
make -j4
make check
make install
cp COPYING COPYING.LESSER "$prefix/"
cd "$sources"
curl --fail --location --retry 3 -o openssl.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz
echo '243a86649cf6f23eeb6a2ff2456e09e5d77dd9018a54d3d96b0c6bdd6ba6c7f1  openssl.tar.gz' | shasum -a 256 -c -
tar -xf openssl.tar.gz
cd openssl-3.6.3
node "$helper/scripts/sync-openssl-test.js" "$PWD"
case "$(uname -m)" in
  arm64) target=darwin64-arm64-cc ;;
  x86_64) target=darwin64-x86_64-cc ;;
  *) exit 1 ;;
esac
./Configure "$target" no-shared no-dso no-module --prefix="$prefix" --libdir=lib
make -j4
# Keep the upstream test runner serial; parallel QUIC tests were unreliable.
make test
make install_sw
cp LICENSE.txt "$prefix/"
