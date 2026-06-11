#!/bin/zsh
# Start the Mac sender app. The phone app must be running (it listens on
# :9000); USB connectivity goes through macOS's built-in usbmuxd — no tunnel
# tool needed. The Mac app retries until the device shows up.
set -e
cd "$(dirname "$0")"

APP=build/Build/Products/Debug/OpenSidecar.app
if [[ ! -d $APP ]]; then
  echo "Mac app not built — run: xcodegen generate && xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac -configuration Debug -derivedDataPath build build"
  exit 1
fi

open "$APP"
echo "OpenSidecar running — logs at /tmp/opensidecar-mac.log."
