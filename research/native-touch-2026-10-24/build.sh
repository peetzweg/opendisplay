#!/bin/sh
# Builds TouchProbe.app next to this script. Ad-hoc signed with a fixed
# identifier so Input Monitoring / Accessibility grants survive rebuilds of the
# same binary (rebuilding changes the cdhash; re-grant if macOS asks again).
set -e
cd "$(dirname "$0")"
APP=TouchProbe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.opendisplay.research.touchprobe</string>
  <key>CFBundleName</key><string>TouchProbe</string>
  <key>CFBundleExecutable</key><string>TouchProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/TouchProbe" TouchProbe.swift
codesign -f -s - --identifier dev.opendisplay.research.touchprobe "$APP"
echo "built $(pwd)/$APP"
