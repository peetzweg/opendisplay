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

- AirPlay audio output: the app can act as an RAOP audio sink for AirPlay
  senders such as iPhone/Mac. Settings has an "Allow AirPlay audio" switch,
  enabled by default; it controls a foreground service that accepts ALAC/AAC
  audio and metadata. AirPlay mirroring, AirPlay video, photos and HLS are
  not implemented here, and the existing OpenDisplay screen-cast path is
  separate.

- Video compatibility: an opt-in "Legacy decoder compatibility" switch uses
  the software H.264 decoder, 16-pixel aligned frames and a 15 fps cap for old
  vendor OMX decoders. It is off by default, so Android 7+ keeps the normal
  hardware path. Enable it only if the picture shows diagonal stripes or
  colour blocks on Android 5/6.

Not yet: sender-side ADB discovery.

## Build and install

Needs JDK 17, Android SDK platform 36, and NDK 27.0.12077973 for the embedded
AirPlay audio engine.

The separately licensed native source trees are not committed; they are
downloaded before CMake configuration. See
[Third-party dependency download](#third-party-dependency-download) below.

```sh
./gradlew assembleDebug                 # app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug                  # onto the connected device
./gradlew testDebugUnitTest lintDebug   # JVM tests + lint (catches API > minSdk)
```

To compile only the Kotlin/UI parts when the NDK is not installed, add
`-PskipAirplayNative=true`; such a build does not contain the native AirPlay
engine and the audio receiver will safely no-op and will not download the
third-party trees.

The debug build installs as `com.peetzweg.opendisplay.debug` ("OpenDisplay
Dev") next to a release build.

## Third-party dependency download

The native AirPlay engine is built from pinned upstream commits. Those source
trees are licensed separately and are **not stored in this repository**. Only
our patches, the bootstrap script and the licence notices are committed. The
exact commits, licences and the OpenSSL tarball hash are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Automatic download

A normal native build downloads everything automatically before CMake runs:

```sh
./gradlew assembleDebug
```

You can trigger just the download step without compiling:

```sh
./gradlew prepareAirplayThirdParty
```

The task is incremental: an existing complete tree is detected and preserved,
so it does not re-download on every build.

### Manual download

If you prefer to run the bootstrap directly, or need to pass a proxy:

```sh
python3 tools/bootstrap-airplay-third-party.py
python3 tools/bootstrap-airplay-third-party.py --proxy http://host:port
python3 tools/bootstrap-airplay-third-party.py --force
```

- `--force` removes and replaces the downloaded trees.
- `HTTP_PROXY` and `HTTPS_PROXY` environment variables are also honoured.
- Through Gradle, use `-PairplayBootstrapProxy=http://host:port` or
  `-PforceAirplayBootstrap=true`.

The bootstrap downloads UxPlay, FFmpeg, libplist, openssl-cmake and the OpenSSL
3.4.4 tarball into `app/src/main/cpp/third_party`, verifies the OpenSSL SHA-256,
applies the patches in `app/src/main/cpp/patches/UxPlay`, and writes a marker
file when finished. It needs at least 256 MiB of free space; a full native
build needs substantially more.

After a successful run, these paths exist:

```text
app/src/main/cpp/third_party/UxPlay
app/src/main/cpp/third_party/ffmpeg
app/src/main/cpp/third_party/libplist
app/src/main/cpp/third_party/openssl-cmake/openssl-3.4.4.tar.gz
app/src/main/cpp/third_party/.airplay-bootstrap
```

If an older checkout still tracks those trees in Git, remove them from the
index once (the files stay on disk and are recreated on a fresh clone):

```sh
git rm -r --cached \
  app/src/main/cpp/third_party/UxPlay \
  app/src/main/cpp/third_party/ffmpeg \
  app/src/main/cpp/third_party/libplist \
  app/src/main/cpp/third_party/openssl-cmake
```

Do not commit the downloaded trees, `.downloads/`, `.staging/`, the marker
file, or `app/.cxx/`. They are already covered by `.gitignore` for new clones.

## Licensing

The repository is GPL-3.0. The Android audio receiver links UxPlay (GPL-3.0),
FFmpeg under its LGPL-2.1-or-later option, libplist under LGPL-2.1-or-later,
openssl-cmake (MIT), OpenSSL 3.4.4 (Apache-2.0) and Oboe (Apache-2.0). These
licence choices are compatible with GPLv3. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for exact revisions, licence
notes and source availability details.

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
airplay/   RAOP audio sink for AirPlay audio, NSD advertiser, audio renderer
           and JNI bridge
cpp/       native UxPlay/FFmpeg/OpenSSL/Oboe engine for the AirPlay receiver
tools/android/  scripted ffmpeg sender and mock receiver for testing without a Mac
tools/bootstrap-airplay-third-party.py  pinned downstream source bootstrap
```

The repository keeps only our small patches, the bootstrap script and licence
notices. The large upstream source trees are downloaded at build time.
