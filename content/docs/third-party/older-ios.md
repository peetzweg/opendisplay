---
title: Use an older iPhone or iPad (iOS 12) as a second display
nav: Older iPhones and iPads
description: The official OpenDisplay receiver needs iOS 15. Two community receivers bring iPads and iPhones stuck on iOS 12, such as the iPad Air 1, iPad mini 2 and 3 and iPhone 5s and 6, back as a second Mac display.
order: 1
updated: 2026-10-23
---

## Which devices need this

The official OpenDisplay receiver on the App Store needs **iOS / iPadOS 15**
or newer. Devices whose last update is iOS 12 cannot install it:

| Device | Last iOS |
|---|---|
| iPad Air (1st generation) | 12.5.x |
| iPad mini 2, iPad mini 3 | 12.5.x |
| iPhone 5s, iPhone 6, iPhone 6 Plus | 12.5.x |

If your device runs iOS 15 or newer, use the
[official app](https://apps.apple.com/app/id6780264891) instead. Devices
that stop before iOS 12 (for example the iPad 4th generation or the original
iPad mini) are not covered by either project below.

Both projects are **receivers only**: the Mac runs the normal, unmodified
[OpenDisplay sender](https://github.com/peetzweg/opendisplay/releases/latest).
Neither is on the App Store, so you install them yourself: one with a
sideloading tool and a free Apple ID, the other with an Apple Developer
account or a jailbreak.

> These are community projects, not official builds. See
> [Third-party apps](/docs/third-party/) for what that means.

## iOSLegacy: the official receiver code on iOS 12

[Francesco149/opendisplay, `iOSLegacy`](https://github.com/Francesco149/opendisplay/tree/ios12-legacy-receiver/iOSLegacy)
compiles the official receiver's own code (the stream receiver, the receiver
model and the video view) for iOS 12.2+ inside a small UIKit app. Only the app
shell differs, so it behaves like the App Store receiver.

- **Runs on:** iOS 12.2 or newer, iPad Air, iPad mini 2/3, iPhone 5s/6/6 Plus.
- **Tested by its author:** iPad Air on iOS 12.5.8 over USB with the stock Mac
  sender: 2048×1536 H.264, rotation and touch, about 11 ms median
  capture-to-display latency.
- **Video:** H.264 only. These chips are capped at about 42 fps at the full
  panel resolution, which the sender respects automatically.
- **Install:** build it on a Mac with the project's `iOSLegacy/build.sh`
  (current Xcode no longer targets iOS 12, so the script drives the compilers
  directly). Then either register the device's UDID with an Apple Developer
  team, rebuild against that profile and install the `.ipa` with
  `ideviceinstaller -i`, or, on a jailbroken device, copy the app into
  `/Applications`. There is no prebuilt download. The steps are in its
  [README](https://github.com/Francesco149/opendisplay/tree/ios12-legacy-receiver/iOSLegacy).
- **Status:** proposed for this repository in
  [#389](https://github.com/peetzweg/opendisplay/pull/389).

## ipad-iphone-second-monitor-ios12-free

[cuongpham1/ipad-iphone-second-monitor-ios12-free](https://github.com/cuongpham1/ipad-iphone-second-monitor-ios12-free)
is an independent, clean-room iOS 12 client of the same protocol, with a
prebuilt app.

- **Runs on:** iOS 12.0 or newer, iPad and iPhone (an iPad is the useful case).
- **Tested by its author:** iPad Air (A1475) on iOS 12.5.8 over a Lightning
  cable and over Wi-Fi: H.264 video, touch, two-finger scroll and a cursor.
- **Connection:** Wi-Fi on the same network, or a Lightning cable for steadier
  latency; the Mac prefers the cable and falls back to Wi-Fi.
- **Install:** download `LegacyPadDisplay.ipa` from its
  [latest release](https://github.com/cuongpham1/ipad-iphone-second-monitor-ios12-free/releases/latest)
  and install it with Sideloadly or AltServer using a free Apple ID, then
  trust your Apple ID under **Settings → General → Profiles & Device
  Management** on the device.

## Which one to pick

| | iOSLegacy | ipad-iphone-second-monitor-ios12-free |
|---|---|---|
| Code | The official receiver's code | Independent client |
| Minimum iOS | 12.2 | 12.0 |
| Prebuilt app | No, build it yourself | Yes, `.ipa` on GitHub releases |
| Install with | Apple Developer team profile, or a jailbreak | Sideloadly or AltServer, free Apple ID |
| Tested over | USB | Lightning cable and Wi-Fi |

If you have an Apple Developer account and want behaviour closest to the App
Store receiver, use iOSLegacy. If you want to install a prebuilt file with a
free Apple ID, use ipad-iphone-second-monitor-ios12-free.

## Sideloading notes

- An app signed with a free Apple ID stops launching after **7 days**;
  re-sign it with the sideloading tool. A paid developer account's profile
  lasts a year.
- If the device no longer trusts the Mac, sideloading tools fail until you
  reset trust on the device and tap **Trust** again when you reconnect.
- The Mac side needs nothing special: install OpenDisplay as usual and grant
  Screen Recording and Accessibility.
