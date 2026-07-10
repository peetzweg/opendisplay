# OpenDisplay Android 接收端

OpenDisplay Mac/Android CN 分支的 Android WiFi 与 ADB-over-USB 接收端。

English version: [README.md](README.md)

本模块让 Android 平板作为 Mac 发送端的接收器。它与 iOS 应用遵循相同的
OpenDisplay 接收端协议约定：兼容 Bonjour 的服务发现、length-prefixed TCP
数据流、H.264 视频帧，以及用于输入和保活的 JSON 控制消息。

## 概述

安卓端的定位是“平板接收器”，不是独立投屏软件。Mac 端负责创建镜像或扩展显示器、捕获画面、编码 H.264 并通过局域网发送；安卓端负责发现/监听、解码、显示画面，并把触摸和滚动事件回传给 Mac。

当前已经实现：

- Android NSD 广播 `_opensidecar._tcp`
- TCP 监听端口 `9000`
- Mac 端通过 ADB 自动发现 USB 设备，并将空闲本地端口转发到设备的 `tcp:9000`
- 与 Mac 端兼容的 length-prefixed JSON 控制帧
- H.264 Annex B 视频帧接收
- `MediaCodec` 解码到 `SurfaceView`
- Mac 鼠标位置绘制
- 轻点、拖拽、双指滚动输入
- 英文默认界面，并保留中文启动、状态和设置翻译
- 端到端延迟、编码延迟、RTT 与 FPS 状态显示开关
- 始终通告原生屏幕尺寸；串流画质由 Mac 端控制，无需重建虚拟显示器

已在本地真机验证：

- Android 平板能出现在 Mac 端 WiFi 设备列表
- Mac 可以通过 WiFi 镜像和扩展到 Android
- H.264 画面能正常解码显示
- 点击屏幕不会导致 app 退出
- 鼠标位置可以在 Android 屏幕上显示

## 接收端协议约定

Android 接收端遵循以下约定：

```text
Android receiver
  advertise _opensidecar._tcp
  listen on TCP :9000
  send hello JSON
  receive length-prefixed H.264 Annex B frames
  render through MediaCodec
  send touch / scroll / ping / keyframe JSON messages
```

重要协议细节：

- 每个载荷都带有 4 字节大端序长度前缀。
- JSON 控制消息和视频载荷共用同一条数据流。
- 视频帧为 H.264 Annex B 格式。
- 接收端发送带有显示尺寸和设备元数据的 `hello` 消息。
- 触摸坐标经过归一化，Mac 端可将其映射到当前显示器上。

## 模块结构

```text
app/src/main/java/app/opendisplay/android/
  MainActivity.java              Android UI 与 SurfaceView 宿主
  OpenDisplayServer.java         TCP 服务器、NSD 生命周期、数据流处理
  H264SurfaceDecoder.java        MediaCodec 视频解码
  CursorOverlayView.java         Mac 光标绘制
  TouchGestureCoordinator.java   轻点/拖拽手势暂存
  ScrollGestureTracker.java      双指滚动增量
  protocol/                      长度前缀、Annex B、SPS、控制消息解析

tests/java/
  ProtocolSelfTest.java          协议与输入行为检查
```

## 设计说明

- **Surface 优先渲染**：`MediaCodec` 直接渲染到 `SurfaceView`，避免额外的帧拷贝。
- **触摸写入不在 UI 线程**：控制消息通过 `ControlMessageWriter` 排队发送，避免 Android 的 `NetworkOnMainThreadException`。
- **轻点延迟判定避免滚动误触**：单指按下事件会短暂保留，直到手势类型明确；第二根手指会取消待定的轻点。
- **原生显示尺寸保持稳定**：Android 始终通告面板原生尺寸。Mac 端画质设置只缩放捕获和编码，不会拆除并重建虚拟显示器。
- **光标与视频分离**：Mac 通过控制消息发送光标位置和图像元数据，Android 以叠加层方式绘制。

## 已知限制

- Android USB 模式需要 Mac 上安装 Android Platform Tools（`adb`），并在 Android 设备上授权 USB 调试。
- 传输为局域网 TCP，尚未实现生产级的加密配对。
- 硬件解码器的行为可能因 Android 厂商而异。
- 多点触控目前映射为实用的桌面手势，并非完整的 macOS 手势集。
- 尚未配置应用商店分发。

## 验证

实用的本地检查：

```bash
cd Android && ./gradlew testDebugUnitTest assembleDebug
```

Gradle Wrapper 是标准构建方式，需要 JDK 17 或更高版本。涉及 Android
接收端的 Pull Request 会在 GitHub Actions 中运行单元测试并构建 debug APK。
APK 位于 `Android/app/build/outputs/apk/debug/app-debug.apk`；连接设备后，可用
`cd Android && ./gradlew installDebug` 安装。

USB 模式下，在 Android 上开启开发者选项和 USB 调试，连接设备，允许 Mac
的调试密钥，然后打开接收端应用。Mac 应用会自动发现 `adb devices` 并使用
自动分配的本地端口转发，等价于：

```bash
adb -s DEVICE_SERIAL forward tcp:0 tcp:9000
```

使用 `tcp:0` 让 ADB 自行选择空闲的 Mac 侧端口，因此每个接收端都可以固定
使用 `9000` 端口，并支持同时连接多台 Android 设备。

协议自测覆盖：长度前缀往返（包括超过 1 MiB 的帧）、控制消息分类、H.264
Annex B 解析、SPS 尺寸解析、安全的触摸指针处理、滚动增量、轻点延迟判定，
以及后台控制消息写入。

## 上游兼容性

本接收端有意沿用现有的 OpenDisplay 接收端形态，使 Mac 发送端无需单独的
Android 专用流协议。除非有明确理由引入带版本的协议能力协商，Android
功能应尽量贴近该协议约定。
