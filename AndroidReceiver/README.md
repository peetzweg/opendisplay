# OpenDisplay Android Receiver

Android WiFi receiver for OpenDisplay.

The Mac app already streams H.264 over TCP to receivers discovered through
Bonjour/mDNS. This Android app implements the same receiver-side contract:

- advertise `_opensidecar._tcp` on port `9000`
- send a length-prefixed JSON `hello` after the Mac connects
- receive length-prefixed H.264 Annex B frames from the Mac
- send length-prefixed JSON touch and liveness messages back to the Mac

Open this folder in Android Studio and run the `app` target on an Android
tablet connected to the same LAN as the Mac.

## Build Without Gradle

This workspace currently has Android Studio and the Android SDK, but no
command-line Gradle distribution. Until Gradle is configured, build a debug APK
with:

```bash
AndroidReceiver/scripts/build_debug_apk.sh
```

The script writes:

```text
AndroidReceiver/dist/OpenDisplayAndroid-debug.apk
```

Install it with Android Studio or `adb install` after connecting an Android
tablet with USB debugging enabled.

## Current Scope

Implemented:

- WiFi service advertisement through Android NSD as `_opensidecar._tcp`
- TCP listener on port `9000`
- Mac-compatible length-prefixed JSON control frames
- Mac-compatible H.264 Annex B video frame receiver
- `MediaCodec` decode to `SurfaceView`
- touch events sent back to the Mac as normalized `touch` messages
- Mac cursor rendering on Android
- tap, drag, and two-finger scroll input
- Chinese onboarding, settings, and streaming status UI
- optional latency/FPS status display
- Android-side display quality profiles: native, balanced, and fast

Verified locally:

- Android tablet appears in the Mac app's WiFi device list
- Mac can mirror and extend to Android over WiFi
- H.264 decoder renders the streamed desktop
- touch input no longer crashes the app
- cursor position is visible on the Android display
