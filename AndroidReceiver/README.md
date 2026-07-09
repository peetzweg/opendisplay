# OpenDisplay Android Receiver

Android WiFi receiver for the OpenDisplay Mac/Android CN fork.

This module lets an Android tablet act as a receiver for the Mac sender. It
uses the same OpenDisplay receiver contract as the iOS app: Bonjour-compatible
service discovery, a length-prefixed TCP stream, H.264 video frames, and JSON
control messages for input and liveness.

## 中文说明

安卓端的定位是“平板接收器”，不是独立投屏软件。Mac 端负责创建镜像或扩展显示器、捕获画面、编码 H.264 并通过局域网发送；安卓端负责发现/监听、解码、显示画面，并把触摸和滚动事件回传给 Mac。

当前已经实现：

- Android NSD 广播 `_opensidecar._tcp`
- TCP 监听端口 `9000`
- 与 Mac 端兼容的 length-prefixed JSON 控制帧
- H.264 Annex B 视频帧接收
- `MediaCodec` 解码到 `SurfaceView`
- Mac 鼠标位置绘制
- 轻点、拖拽、双指滚动输入
- 中文启动、状态和设置界面
- 延迟/FPS 状态显示开关
- 原生、均衡、流畅三档画质/分辨率配置

已在本地真机验证：

- Android 平板能出现在 Mac 端 WiFi 设备列表
- Mac 可以通过 WiFi 镜像和扩展到 Android
- H.264 画面能正常解码显示
- 点击屏幕不会导致 app 退出
- 鼠标位置可以在 Android 屏幕上显示

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

- Android support is WiFi-only in this fork.
- The transport is local-network TCP and is not yet production-grade encrypted pairing.
- Hardware decoder behavior can vary by Android vendor.
- Multi-touch is currently mapped to practical desktop gestures, not a full macOS gesture set.
- Store distribution is not configured.

## Verification

Useful local checks:

```bash
AndroidReceiver/scripts/build_debug_apk.sh
```

The protocol self-test covers length-prefix round trips, control message
classification, H.264 Annex B parsing, SPS dimension parsing, cursor control
messages, safe touch pointer handling, scroll deltas, tap deferral, and
background control-message writes.

## Upstream Compatibility

This receiver intentionally uses the existing OpenDisplay receiver shape so the
Mac sender does not need a separate Android-only streaming protocol. Android
features should stay close to that contract unless there is a clear reason to
add versioned protocol capability negotiation.
