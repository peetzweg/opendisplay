#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
PLATFORM="${ANDROID_PLATFORM:-android-36.1}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-37.0.0}"
JBR="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
WORK_DIR="${TMPDIR:-/tmp}/opendisplay-android-manual"
OUT_DIR="$ROOT_DIR/dist"
KEYSTORE="$OUT_DIR/debug.keystore"

AAPT2="$ANDROID_SDK/build-tools/$BUILD_TOOLS/aapt2"
D8="$ANDROID_SDK/build-tools/$BUILD_TOOLS/d8"
APKSIGNER="$ANDROID_SDK/build-tools/$BUILD_TOOLS/apksigner"
ANDROID_JAR="$ANDROID_SDK/platforms/$PLATFORM/android.jar"
JAVAC="$JBR/bin/javac"
JAVA="$JBR/bin/java"
KEYTOOL="$JBR/bin/keytool"

for tool in "$AAPT2" "$D8" "$APKSIGNER" "$ANDROID_JAR" "$JAVAC" "$JAVA" "$KEYTOOL"; do
  if [[ ! -e "$tool" ]]; then
    echo "missing build dependency: $tool" >&2
    exit 1
  fi
done

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/res" "$WORK_DIR/gen" "$WORK_DIR/classes" "$WORK_DIR/dex" "$OUT_DIR"

"$AAPT2" compile --dir "$ROOT_DIR/app/src/main/res" -o "$WORK_DIR/res"
RES_FLATS=()
while IFS= read -r flat; do
  RES_FLATS+=("$flat")
done < <(find "$WORK_DIR/res" -name '*.flat' | sort)
sed 's/<manifest /<manifest package="app.opendisplay.android" /' \
  "$ROOT_DIR/app/src/main/AndroidManifest.xml" > "$WORK_DIR/AndroidManifest.xml"

"$AAPT2" link \
  -I "$ANDROID_JAR" \
  --manifest "$WORK_DIR/AndroidManifest.xml" \
  --java "$WORK_DIR/gen" \
  --min-sdk-version 26 \
  --target-sdk-version 36 \
  --version-code 1 \
  --version-name 0.1 \
  --debug-mode \
  -o "$WORK_DIR/OpenDisplayAndroid-unsigned.apk" \
  "${RES_FLATS[@]}"

"$JAVAC" -Xlint:-options -source 17 -target 17 \
  -cp "$ANDROID_JAR" \
  -d "$WORK_DIR/classes" \
  $(find "$ROOT_DIR/app/src/main/java" "$WORK_DIR/gen" -name '*.java')

JAVA_HOME="$JBR" PATH="$JBR/bin:$PATH" "$D8" \
  --min-api 26 \
  --lib "$ANDROID_JAR" \
  --output "$WORK_DIR/dex" \
  $(find "$WORK_DIR/classes" -name '*.class')

(
  cd "$WORK_DIR/dex"
  zip -q "$WORK_DIR/OpenDisplayAndroid-unsigned.apk" classes.dex
)

if [[ ! -e "$KEYSTORE" ]]; then
  "$KEYTOOL" -genkeypair \
    -keystore "$KEYSTORE" \
    -storepass android \
    -keypass android \
    -alias androiddebugkey \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Android Debug,O=OpenDisplay,C=CN" >/dev/null
fi

JAVA_HOME="$JBR" PATH="$JBR/bin:$PATH" "$APKSIGNER" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --out "$OUT_DIR/OpenDisplayAndroid-debug.apk" \
  "$WORK_DIR/OpenDisplayAndroid-unsigned.apk"

JAVA_HOME="$JBR" PATH="$JBR/bin:$PATH" "$APKSIGNER" verify --verbose \
  "$OUT_DIR/OpenDisplayAndroid-debug.apk"

echo "APK: $OUT_DIR/OpenDisplayAndroid-debug.apk"
