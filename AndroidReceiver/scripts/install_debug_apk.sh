#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ADB="$ANDROID_SDK/platform-tools/adb"
APK="$ROOT_DIR/dist/OpenDisplayAndroid-debug.apk"
PACKAGE="app.opendisplay.android"
ACTIVITY="$PACKAGE/.MainActivity"

if [[ ! -e "$ADB" ]]; then
  echo "missing adb: $ADB" >&2
  exit 1
fi

if [[ ! -e "$APK" ]]; then
  "$ROOT_DIR/scripts/build_debug_apk.sh"
fi

device_count="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { count++ } END { print count + 0 }')"
if [[ "$device_count" -eq 0 ]]; then
  "$ADB" devices
  echo "没有检测到已授权的 Android 设备。请连接 USB 或开启无线调试，并在设备上允许调试授权。" >&2
  exit 1
fi

set +e
install_output="$("$ADB" install -r "$APK" 2>&1)"
install_status=$?
set -e
printf '%s\n' "$install_output"
if [[ "$install_status" -ne 0 ]]; then
  echo "安装失败。如果提示签名不兼容，请先手动卸载旧版 OpenDisplay Android 后再运行此脚本。" >&2
  exit "$install_status"
fi

"$ADB" shell am start -n "$ACTIVITY"
