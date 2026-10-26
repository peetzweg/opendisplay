---
title: Third-party Android receivers for OpenDisplay
nav: Android receivers
description: Community Android receivers for OpenDisplay, including one built for GrapheneOS and de-Googled Pixel devices, as alternatives to the official Android beta on Google Play.
order: 3
updated: 2026-10-24
---

## Official receiver first

OpenDisplay has its own Android receiver, in public beta on Google Play
(Android 7.0+, over Wi-Fi or a USB cable); the link is on the
[home page](/). Use it if your device has Google Play.

### Over a USB cable

No developer options, USB debugging or tethering needed:

1. Plug the device into the Mac with OpenDisplay running.
2. The first time, click the device in OpenDisplay on the Mac to connect.
3. Android asks to open OpenDisplay for the USB accessory. Tick **Always**
   and confirm.

From then on, plugging in is enough: the Mac connects and Android opens the
app by itself. While connected, the device's USB file transfer is off; it
comes back when the session ends. A locked device connects once it is
unlocked.

The community receivers below are for devices without Google Play, such as
**GrapheneOS** phones and tablets, or for connection setups the official
beta does not cover yet, such as networks that block connections between
devices.

> These are community projects, not official builds. See
> [Third-party apps](/docs/third-party/) for what that means.

## android-opendisplay (GrapheneOS)

[gprot42/android-opendisplay](https://github.com/gprot42/android-opendisplay)
is a receiver built for de-Googled Pixel hardware.

- **Runs on:** Android 8.0+ (API 26); built for and tested on a Google Pixel
  Tablet with GrapheneOS. Stock Android is not its focus.
- **Connection:** Wi-Fi with the official Mac app connecting to the device as
  usual. For guest Wi-Fi, AP isolation or VPNs that block that, it adds a
  **reverse connect** mode where the device dials the Mac, plus USB through
  `adb` and USB tethering. Reverse connect needs the project's own build of
  the Mac app.
- **Extras:** mirror mode, and system audio played on the device or the Mac.
- **Install:** build the APK with Gradle (JDK 17+ and the Android SDK) and
  install it with `adb install`; see its README.

## opendisplay-android

[josepacelli/opendisplay-android](https://github.com/josepacelli/opendisplay-android)
is an Android receiver that works with the **unmodified** OpenDisplay Mac app.

- **Runs on:** Android 8.0+ (API 26). Tested by its author on Samsung Galaxy
  Tab S9 FE+, Galaxy Note10+ and Galaxy Tab S7+, Android 12 to 16.
  Versions 0.0.7 and older crash on launch on Android 12–13; use a newer
  release.
- **Connection:** the same Wi-Fi network as the Mac, or a USB cable with
  `adb forward`.
- **Install:** download the APK from its
  [latest release](https://github.com/josepacelli/opendisplay-android/releases/latest)
  and sideload it (`adb install`, or copy it to the device and allow apps from
  unknown sources).
- **Licence:** GPL-3.0.

## Compared

| | Official beta | android-opendisplay | opendisplay-android |
|---|---|---|---|
| Android | 7.0+ | 8.0+ (GrapheneOS focus) | 8.0+ |
| Needs Google Play | Yes | No | No |
| Connection | Wi-Fi, USB | Wi-Fi, reverse connect, USB (adb, tethering) | Wi-Fi, USB (`adb forward`) |
| Mac app | Official | Official; its own build for reverse connect | Official |
| Install | Google Play | Build from source | APK from GitHub releases |
