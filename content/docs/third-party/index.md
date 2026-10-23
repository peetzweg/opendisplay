---
title: Third-party apps compatible with OpenDisplay
nav: Third-party apps
description: Community-built senders and receivers that speak the OpenDisplay protocol, for devices and systems the official apps do not cover yet, such as iPads on iOS 12, Linux X11 desktops and de-Googled Android.
order: 20
updated: 2026-10-23
---

## What these are

OpenDisplay is an open protocol as well as a set of apps. Every sender and
receiver speaks the same [wire protocol](https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md),
so people have built their own clients for devices and systems the official
apps do not cover. Most of them work with the **unmodified** official app on
the other end: an old iPad runs a community receiver and the Mac runs the
normal OpenDisplay sender, or a Linux PC runs a community sender and the iPad
runs the App Store receiver.

> **Not official.** These are fan-made projects. They are not affiliated with
> OpenDisplay and are not maintained, reviewed or supported by us, and we have
> not tested every one of them. Report problems in each project's own
> repository. Listing a project here says nothing about our plans: an official
> app may still ship for any of these platforms later.

## Which one do I need?

| I want to… | Use | Page |
|---|---|---|
| Use an iPad or iPhone stuck on **iOS 12** (iPad Air 1, iPad mini 2/3, iPhone 5s/6) as a Mac display | A community iOS 12 receiver | [Older iPhones and iPads](/docs/third-party/older-ios/) |
| Extend a **Linux X11** desktop (Linux Mint, Ubuntu on Xorg, …) onto an iPad | `opendisplay-x11` | [Linux senders](/docs/third-party/linux/) |
| Extend a **Linux Wayland** desktop onto an iPhone or iPad | The official [Linux sender (beta)](/docs/linux/) first; community alternative listed | [Linux senders](/docs/third-party/linux/) |
| Use a **de-Googled Android** device (GrapheneOS), or an Android receiver with reverse connect or USB | A community Android receiver | [Android receivers](/docs/third-party/android/) |

For anything the official apps already cover, use those: they are on the
[home page](/) and listed in [the docs overview](/docs/#platforms).

## All projects

| Project | Role | Runs on | Pairs with | Connection | Install |
|---|---|---|---|---|---|
| [Francesco149/opendisplay (iOSLegacy)](https://github.com/Francesco149/opendisplay/tree/ios12-legacy-receiver/iOSLegacy) | Receiver | iOS 12.2+ (iPad Air, iPad mini 2/3, iPhone 5s/6/6 Plus) | Official Mac sender | USB (tested) | Build it; developer profile or jailbreak |
| [cuongpham1/ipad-iphone-second-monitor-ios12-free](https://github.com/cuongpham1/ipad-iphone-second-monitor-ios12-free) | Receiver | iOS 12.0+ iPad and iPhone | Official Mac sender | Lightning (USB), Wi-Fi | Prebuilt `.ipa`, sideload |
| [cray2015/opendisplay-x11](https://github.com/cray2015/opendisplay-x11) | Sender | Linux X11 with a free HDMI/DP++ port | Official iPad receiver | USB cable only | `.deb` from GitHub releases (Linux Mint 22 / Ubuntu 24.04+) |
| [tixwho/opendisplay-linux](https://github.com/tixwho/opendisplay-linux) | Sender | Linux Wayland: KDE Plasma, Hyprland | Official iPhone/iPad receiver | Wi-Fi, USB | Build from source (CMake, Arch `PKGBUILD`) |
| [gprot42/android-opendisplay](https://github.com/gprot42/android-opendisplay) | Receiver | Android 8.0+, built for GrapheneOS on Pixel | Official Mac sender; reverse connect needs the project's own Mac build | Wi-Fi, reverse connect, USB via adb | Build from source |
| [josepacelli/opendisplay-android](https://github.com/josepacelli/opendisplay-android) | Receiver | Android 8.0+ | Official Mac sender | Wi-Fi, USB via `adb forward` | APK from GitHub releases |

The details, requirements and status of each are on the platform pages.

## Get your project listed

Built something that speaks the OpenDisplay protocol? Open a pull request that
adds it to the matching page under
[`content/docs/third-party/`](https://github.com/peetzweg/opendisplay/tree/main/content/docs/third-party)
and to the table above, with:

- what it runs on and which official app it pairs with;
- how to install it, and how you tested it (devices, OS versions);
- a link to its repository, which should have a README and a licence.

The protocol is specified in
[PROTOCOL.md](https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md).
A receiver that announces `pv` 3 in its `hello` works with current senders.
