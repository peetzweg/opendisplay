# Architecture

OpenDisplay is split into sender and receiver apps. The Mac app owns display
creation, capture, encoding, transport, and input injection. Receiver apps own
device discovery, decode, presentation, and user input collection.

## System Shape

```text
Mac sender
  display source
    mirror: existing macOS display
    extend: CGVirtualDisplay
  capture: ScreenCaptureKit
  encode: VideoToolbox H.264
  transport: length-prefixed TCP
  input: CGEvent injection

iOS receiver
  transport: Network.framework listener
  decode/render: AVSampleBufferDisplayLayer
  input: UIKit touch events

Android receiver
  discovery: Android NSD
  transport: TCP ServerSocket
  decode/render: MediaCodec + SurfaceView
  input: Android touch events
```

## Data Flow

1. The receiver advertises or listens on port `9000`.
2. The Mac discovers the receiver through USB or WiFi.
3. The receiver sends a JSON `hello` message with display and device metadata.
4. The Mac chooses mirror or extend mode.
5. The Mac captures frames, encodes H.264, and sends length-prefixed payloads.
6. The receiver decodes and presents frames.
7. The receiver sends touch, scroll, ping, and keyframe-control JSON messages.
8. The Mac maps input onto the active display and injects macOS events.

## Transport

All receiver payloads use the same frame format:

```text
[4-byte big-endian length][payload bytes]
```

Payload types:

- H.264 Annex B video frame data
- JSON control messages such as `hello`, `touch`, `scroll`, `ping`, `pong`,
  `kf`, `cursor`, and `cursorImg`

This keeps the protocol simple enough for iOS and Android to share one sender
implementation, while still allowing platform-specific receiver internals.

## Mac Sender

Important responsibilities:

- discover USB and WiFi receivers
- create or select the display source
- keep virtual-display geometry in sync with receiver dimensions
- capture via ScreenCaptureKit
- encode with low-latency H.264 settings
- apply backpressure and request keyframes when needed
- inject touch and scroll input through Accessibility APIs
- expose user-facing state in the SwiftUI app

The Mac app needs Screen Recording for capture and Accessibility for injected
input. Local Network permission is needed for WiFi discovery.

## iOS Receiver

The iOS receiver is the original receiver target. It keeps the app in the
foreground, listens for the Mac, renders H.264 frames, and sends UIKit touch
events back as normalized control messages.

This fork mainly changes iOS user-facing text and keeps the receiver behavior
compatible with upstream.

## Android Receiver

The Android receiver mirrors the iOS receiver contract while using Android
platform APIs:

- `NsdAdvertiser` publishes `_opensidecar._tcp`
- `OpenDisplayServer` owns the TCP server and stream loop
- `H264SurfaceDecoder` manages `MediaCodec`
- `CursorOverlayView` draws the Mac cursor above the video surface
- `TouchGestureCoordinator` maps tap and drag gestures
- `ScrollGestureTracker` maps two-finger scroll
- `DisplayProfile` controls the advertised resolution profile

Android control writes are kept off the UI thread to avoid runtime crashes.

## Design Constraints

- The system is local-first and should not require external servers.
- The sender should not grow Android-only assumptions when capability
  negotiation can preserve iOS compatibility.
- Any new protocol field should be optional or versioned.
- Display and input changes should be verified in mirror and extend modes.
- Build artifacts, generated projects, and APK outputs should stay out of Git.

## Risk Areas

- `CGVirtualDisplay` is a private macOS API and can change across macOS updates.
- WiFi transport is latency-sensitive and can be affected by routers, VPN TUN
  mode, multicast filtering, and Android vendor networking behavior.
- Android hardware decoders differ by device.
- Accessibility and Screen Recording permissions fail silently in some macOS
  states, so user-facing diagnostics matter.
