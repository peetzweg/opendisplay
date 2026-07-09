<div align="center">

<img src="public/logo.png" width="128" alt="OpenDisplay app icon" />

# OpenDisplay Mac/Android CN

**Use an Android tablet, iPhone, or iPad as an extra Mac display.**

This fork extends [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay)
with an Android WiFi receiver, Chinese UI copy, Mac Dock/window polish, and
input fixes for touch, cursor, and scrolling.

[Architecture](ARCHITECTURE.md) · [Roadmap](ROADMAP.md) · [Contributing](CONTRIBUTING.md) · [Support](SUPPORT.md) · [Security](SECURITY.md)

</div>

---

## 中文概览

这个仓库是 OpenDisplay 的增强 fork，目标是让更多闲置设备成为 Mac 的第二块屏幕。

当前重点：

- **Android 平板接收端**：通过 WiFi 被 Mac 端发现，接收 H.264 画面并显示为镜像或扩展屏。
- **Mac/iOS 中文化**：主要界面、权限提示、状态说明、性能浮层已改为中文。
- **Mac 桌面体验改进**：默认显示在程序坞，保留主窗口，避免菜单栏图标被淹没。
- **输入链路修复**：Android 端支持鼠标位置显示、轻点、拖拽、双指滚动，并修复触摸导致退出的问题。
- **调试与维护文稿**：补齐架构、路线图、贡献、安全和支持说明，方便后续继续维护。

本 fork 仍然保留原项目的核心价值：本地传输、自托管、开源、无需账号服务器。

## English Summary

This is a focused OpenDisplay fork for Mac-to-Android tablet support and
Chinese localization. The original project already provides a low-latency Mac
sender and iOS receiver. This fork adds an Android receiver that implements the
same receiver-side contract over local WiFi, plus UI and input improvements for
day-to-day use.

The project is useful if you want to explore:

- macOS virtual displays through `CGVirtualDisplay`
- ScreenCaptureKit capture and VideoToolbox H.264 streaming
- Android `MediaCodec` rendering to `SurfaceView`
- touch and scroll control messages from a tablet back to macOS
- a practical Sidecar-like workflow without closed services

## What This Fork Adds

| Area | Status | Notes |
|---|---:|---|
| Android receiver | Working prototype | WiFi discovery, H.264 decode, cursor overlay, touch and scroll input |
| iOS receiver | Localized | Chinese onboarding, settings, permission copy, and performance overlay labels |
| Mac sender | Localized and polished | Chinese UI, Dock/main window mode, mirror-mode input injection fix |
| Input | Improved | Tap deferral avoids two-finger scroll mis-clicks; scroll direction adjusted |
| Quality controls | Added | Android can advertise native, balanced, or fast display profiles |
| Distribution | Source-first | Free Apple ID and local Xcode builds are supported; notarized public release is not configured for this fork |

## Scope

In scope:

- local USB/WiFi display streaming for Mac to iOS/iPadOS
- WiFi streaming from Mac to Android tablets
- Chinese-language product copy and user-facing status text
- local development through Xcode and Android tooling
- documentation that makes the fork understandable and maintainable

Out of scope for now:

- App Store or Play Store distribution
- notarized public macOS releases for this fork
- remote access over the internet
- audio forwarding
- production-grade encrypted pairing

## How It Works

```text
Mac sender
  CGVirtualDisplay / mirror display
  ScreenCaptureKit capture
  VideoToolbox H.264 encode
  TCP length-prefixed frames
        |
        | local USB or WiFi
        v
iOS / Android receiver
  length-prefixed protocol
  H.264 decode
  display surface
  touch / scroll / cursor messages
        |
        v
Mac input injection
```

The receiver listens on port `9000` and advertises `_opensidecar._tcp` for
WiFi discovery. After the Mac connects, the receiver sends a JSON `hello`
message with display metadata. Video frames and JSON control messages then
share the same length-prefixed transport.

For a deeper technical map, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Project Layout

```text
Mac/                 macOS sender app
iOS/                 iPhone/iPad receiver app
AndroidReceiver/     Android tablet WiFi receiver
script/              local helper launcher/build scripts
project.yml          XcodeGen project definition
generate.sh          regenerates OpenSidecar.xcodeproj
```

When `project.yml` changes, regenerate the Xcode project with `./generate.sh`
before building through Xcode.

## Current Validation

The current branch has been verified locally with:

- macOS Debug build for `OpenSidecarMac`
- iOS Simulator Debug build for `OpenSidecariOS`
- Android debug APK build
- Android protocol self-test
- real Android tablet connection over WiFi for mirror/extend, cursor display,
  and touch stability

See [SUPPORT.md](SUPPORT.md) for the diagnostic information that is useful
when reporting problems.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): system design, protocol, and component boundaries
- [ROADMAP.md](ROADMAP.md): maintenance priorities and future work
- [CONTRIBUTING.md](CONTRIBUTING.md): contribution workflow and verification expectations
- [SUPPORT.md](SUPPORT.md): how to report issues with useful context
- [SECURITY.md](SECURITY.md): local-network security model and disclosure policy
- [AndroidReceiver/README.md](AndroidReceiver/README.md): Android receiver details
- [BUILD_IOS_WITH_FREE_APPLE_ID.md](BUILD_IOS_WITH_FREE_APPLE_ID.md): iOS self-signing guide
- [CHANGELOG.md](CHANGELOG.md): upstream history plus fork-specific changes

## Relationship To Upstream

This fork is based on [peetzweg/opendisplay](https://github.com/peetzweg/opendisplay).
The upstream project remains the canonical source for OpenDisplay's original
Mac/iOS implementation and releases.

Changes in this fork are intended to be clear enough to either:

- remain as a practical Android/CN branch, or
- be split into focused pull requests back to upstream.

## License

OpenDisplay is licensed under [GPL-3.0](LICENSE). This fork keeps the same
license and attribution. If you distribute modified builds, keep the source
available under the same license.
