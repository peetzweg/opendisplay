# OpenDisplay receiver for Android

Turns an Android phone or tablet into an extra display for the OpenDisplay
Mac sender. It speaks the same wire protocol as the iPhone/iPad receiver
([PROTOCOL.md](../PROTOCOL.md), pv 3), so the Mac app needs no changes.

Supports Android 5.0 (API 21) and later, so old tablets can be second screens
too. Newer platform features (decoder low-latency mode, display cutouts,
immersive insets) are used when present.

## What works

- Discovery over Wi-Fi: advertises `_opensidecar._tcp` with the TXT `id`/`pv`
  keys, so the device shows up in the Mac app's list.
- Video: H.264 always, HEVC when the device has a hardware HEVC decoder.
  MediaCodec decodes straight to a SurfaceView. Stream changes (rotation,
  quality) rebuild the decoder from the new parameter sets, and lost decode
  state asks the sender for a keyframe.
- The panel (`hello.panel`) is the window in its current orientation at the
  real density, so rotating the device re-shapes the Mac's virtual display.
- Cursor: the Mac pointer is drawn over the video from `cursor`/`cursorImg`,
  over TCP or the UDP side channel (port 9001) on Wi-Fi.
- Input: tap to click, hold or drag to drag, two-finger pan to scroll, using
  the same rules as the iOS receiver (a press waits 120 ms or 10 dp of
  movement before it becomes a mouse-down, so a scroll never clicks).
- Liveness and telemetry: 2 s pings with clock sync, a 5 s watchdog, and
  `stats` every 5 s (shows up as `PHONE-STATS` in the Mac log).
- Locking the phone or leaving the app sends `sleeping`; quitting sends
  `closing`. A sender that goes to sleep blanks the screen.

- Settings and help work like the iOS app: the idle screen's "Settings &
  Help" button, or shake the device anytime (the stream keeps running).
  Status, the name the Mac lists, the performance overlay, a shareable
  connection log, how to connect, and links. First launch shows the same
  "One more app to go" onboarding until the first connection.

- Stylus (S Pen, USI and other active pens): `pencil` down/move/up with
  pressure, tilt and azimuth, `hover` and `proximity` while in range, and
  fingers ignored while the pen is down. Senders below pv 3 get the pen as
  `touch`. Covered by unit tests; not yet tried with real pen hardware.

Not yet: sender-side ADB discovery.

## Build and install

Needs JDK 17 and the Android SDK (platform 35).

```sh
cd Android
./gradlew assembleDebug                 # app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug                  # onto the connected device
./gradlew testDebugUnitTest lintDebug   # JVM tests + lint (catches API > minSdk)
```

The debug build installs as `com.peetzweg.opendisplay.debug` ("OpenDisplay
Dev") next to a release build.

## Connecting

**Wi-Fi:** open the app on the Android device and pick it in the Mac app.
Both need to be on the same network.

**USB:** the Mac sender has no ADB support yet. Forward the receiver's port
and point the sender at it by hand:

```sh
adb forward tcp:9100 tcp:9000
open "OpenDisplay.app" --args -host 127.0.0.1 -port 9100
```

`adb forward` (not `reverse`) is the right direction: the sender dials the
receiver. UDP cannot cross the forward, so the cursor stays on TCP there.

## Measured on a Pixel 10a (Android 17)

Mac sender with `-testPattern YES`, HEVC 2424x1080 at 60 fps:

| Transport | fps | e2e p50 | e2e p95 | RTT |
|---|---|---|---|---|
| USB (`adb forward`) | 60 | ~19 ms | ~22 ms | 3 ms |
| Wi-Fi | 60 | ~24 ms | ~70 ms | 10-20 ms |

End-to-end is capture on the Mac to decoder output on the phone.

## Code map

```
protocol/  framing, demux, Annex B, H.264 SPS size, clock sync, hello,
           cursor sequence, touch gestures (pure Kotlin, unit tested)
net/       ReceiverServer (TCP 9000), CursorChannel (UDP 9001), Advertiser (NSD)
video/     VideoDecoder (MediaCodec), DecoderCaps (videoCaps), StreamStats
ui/        MainActivity, VideoFrame (aspect fit), CursorView, DeviceIdentity
```

`tools/android/` has a scripted ffmpeg sender and a mock receiver for
testing without a Mac.
