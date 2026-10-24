#!/bin/zsh
# Start the Mac sender app. The phone app must be running (it listens on
# :9000); USB connectivity goes through macOS's built-in usbmuxd — no tunnel
# tool needed. The Mac app retries until the device shows up.
set -e
cd "$(dirname "$0")"

APP="build/Build/Products/Debug/OpenDisplay Dev.app"
if [[ ! -d "$APP" ]]; then
  echo "Mac app not built — run: xcodegen generate && xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -configuration Debug -derivedDataPath build build"
  exit 1
fi

# With no Apple Development identity installed, Xcode signs each build ad hoc.
# Its default designated requirement is the binary's changing cdhash, which
# makes macOS forget Screen Recording after every rebuild. Give the Debug app
# one stable requirement based on its already-distinct bundle identifier.
# A real development signature is left untouched.
STABLE_REQUIREMENT='designated => identifier "com.peetzweg.opensidecar.mac.debug"'
if codesign -dv "$APP" 2>&1 | grep -q 'Signature=adhoc' \
    && ! codesign -d -r- "$APP" 2>&1 | grep -Fq "$STABLE_REQUIREMENT"; then
  codesign --force --sign - \
    --requirements "=$STABLE_REQUIREMENT" \
    --entitlements Mac/OpenSidecarMac.entitlements \
    "$APP"
  codesign --verify --deep --strict "$APP"
fi

open "$APP"
echo "OpenDisplay Dev running — logs at ~/Library/Logs/OpenDisplay Dev/opendisplay.log."
