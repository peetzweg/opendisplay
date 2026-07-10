# OpenDisplay Android Receiver

Android WiFi and ADB-over-USB receiver for the OpenDisplay Mac/Android CN fork.

中文版：[README.cn.md](README.cn.md)

This module lets an Android tablet act as a receiver for the Mac sender. It
uses the same OpenDisplay receiver contract as the iOS app: Bonjour-compatible
service discovery, a length-prefixed TCP stream, H.264 video frames, and JSON
control messages for input and liveness.

## Overview

The Android app is a "tablet receiver", not a standalone screen-casting tool.
The Mac side creates the mirrored or extended display, captures the screen,
encodes H.264, and streams it over the local network; the Android side
discovers/listens, decodes, renders the picture, and sends touch and scroll
events back to the Mac.

Currently implemented:

- Android NSD advertisement of `_opensidecar._tcp`
- TCP listener on port `9000`
- Mac discovers USB devices via ADB and forwards a free local port to the device's `tcp:9000`
- Length-prefixed JSON control frames compatible with the Mac sender
- H.264 Annex B video frame reception
- `MediaCodec` decode to a `SurfaceView`
- Mac mouse cursor drawing
- Tap, drag, and two-finger scroll input
- English UI by default, with Chinese launch, status, and settings translations retained
- Latency/FPS status display toggle
- Native, Balanced, and Smooth quality/resolution profiles

Verified on a real device:

- The Android tablet appears in the Mac's WiFi device list
- The Mac can mirror and extend to Android over WiFi
- H.264 video decodes and displays correctly
- Tapping the screen does not crash the app
- The Mac cursor position renders on the Android screen

## Receiver Contract

The Android receiver follows this contract:

```text
Android receiver
  advertise _opensidecar._tcp
  listen on TCP :9000
  send hello JSON
  receive length-prefixed H.264 Annex B frames
  render through MediaCodec
  send touch / scroll / ping / keyframe JSON messages
```

Important protocol details:

- Every payload is prefixed with a 4-byte big-endian length.
- JSON control messages and video payloads share the same stream.
- Video frames are H.264 Annex B.
- The receiver sends a `hello` message with display dimensions and device metadata.
- Touch coordinates are normalized so the Mac can map them onto the active display.

## Module Layout

```text
app/src/main/java/app/opendisplay/android/
  MainActivity.java              Android UI and SurfaceView host
  OpenDisplayServer.java         TCP server, NSD lifecycle, stream handling
  H264SurfaceDecoder.java        MediaCodec video decode
  CursorOverlayView.java         Mac cursor drawing
  TouchGestureCoordinator.java   tap/drag gesture staging
  ScrollGestureTracker.java      two-finger scroll deltas
  DisplayProfile.java            advertised resolution profiles
  protocol/                      length-prefix, Annex B, SPS, control parsing

scripts/
  build_debug_apk.sh             local debug APK builder
  install_debug_apk.sh           local install helper

tests/java/
  ProtocolSelfTest.java          protocol and input behavior checks
```

## Design Notes

- **Surface-first rendering**: `MediaCodec` renders directly to `SurfaceView` to
  avoid extra frame copies.
- **Touch writes are off the UI thread**: control messages are queued through
  `ControlMessageWriter`, avoiding Android's `NetworkOnMainThreadException`.
- **Tap deferral avoids scroll mis-clicks**: single-touch begin events are held
  briefly until the gesture is known; a second finger cancels the pending tap.
- **Display profiles are receiver-driven**: Android can advertise a scaled
  display size so the Mac captures less data for lower-latency WiFi use.
- **Cursor is separate from video**: the Mac sends cursor position and image
  metadata as control messages, and Android draws it as an overlay.

## Known Limits

- Android USB mode requires Android Platform Tools (`adb`) on the Mac and USB
  debugging authorization on the Android device.
- The transport is local-network TCP and is not yet production-grade encrypted pairing.
- Hardware decoder behavior can vary by Android vendor.
- Multi-touch is currently mapped to practical desktop gestures, not a full macOS gesture set.
- Store distribution is not configured.

## Verification

Useful local checks:

```bash
AndroidReceiver/scripts/build_debug_apk.sh
```

For USB, enable Developer options and USB debugging on Android, connect the
device, approve the Mac's debugging key, and open the receiver. The Mac app
discovers `adb devices` automatically and uses an allocated local forward,
equivalent to:

```bash
adb -s DEVICE_SERIAL forward tcp:0 tcp:9000
```

Using `tcp:0` lets ADB choose a free Mac-side port, so port `9000` can remain
fixed on every receiver and multiple Android devices can be connected at once.

The protocol self-test covers length-prefix round trips, control message
classification, H.264 Annex B parsing, SPS dimension parsing, cursor control
messages, safe touch pointer handling, scroll deltas, tap deferral, and
background control-message writes.

## Upstream Compatibility

This receiver intentionally uses the existing OpenDisplay receiver shape so the
Mac sender does not need a separate Android-only streaming protocol. Android
features should stay close to that contract unless there is a clear reason to
add versioned protocol capability negotiation.
