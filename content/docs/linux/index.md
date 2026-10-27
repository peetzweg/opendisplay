---
title: OpenDisplay on Linux
nav: Linux
description: The OpenDisplay Linux sender (beta) extends a Linux desktop onto an iPhone, iPad, Android device or spare Mac; the Linux receiver (beta) makes a Linux machine the display.
order: 10
updated: 2026-10-22
---

## What the Linux sender does

The OpenDisplay Linux sender, `od-sender`, extends a Linux desktop onto an
OpenDisplay receiver: an iPhone, iPad, Android device or spare Mac running the
OpenDisplay app. It creates a **virtual display** on your desktop sized for
the receiver (an "output", in compositor terms), captures it, encodes it as
H.264 and streams it over Wi-Fi. Taps and two-finger scrolls on the receiver
come back as pointer input, and rotating the device rebuilds the virtual
display in portrait.

It speaks the same protocol as the Mac sender, so the receivers from the App
Store, Google Play and the releases page work unchanged. There is no account,
no server and no telemetry: one connection between the two devices.

> **The stream is not encrypted**, so use it on a network you trust.

Video is encoded on the CPU for now (x264); hardware encoding (VA-API) is
planned.

The other direction, a Linux machine as the display, is the
[Linux receiver](/docs/linux/receiver/), also in beta.

## Supported setups

The sender is a **beta**. It is tested on **Omarchy / Hyprland 0.56 on Apple
silicon (Asahi Linux)**; x86_64 is expected to work and needs testers. Sway,
KDE Plasma and GNOME have their own backends, marked **experimental**: each
passes an automated test on a headless copy of that desktop, but none has run
on a real desktop session yet. Reports are very welcome in
[#299](https://github.com/peetzweg/opendisplay/issues/299).

| | Setup |
|---|---|
| **Tested** | Arch / Omarchy, Hyprland 0.56, aarch64 (Asahi Linux on an M1 Pro), CPU encoding. Receivers: iPhone (App Store), Mac receiver app (Intel iMac) |
| **Expected to work** | Arch / Omarchy on x86_64. Any distribution with Hyprland 0.55+. iPad and Android (Google Play beta) as receivers: Android streamed fine in a first session, but touch, scroll, rotation, lock and quit are not checked yet |
| **Experimental** | **Sway 1.10+**, **KDE Plasma 6.8+** (6.7 and older with the desktop entry in place, see [KDE Plasma](/docs/linux/desktops/#kde-plasma)), **GNOME 50+** (older GNOME may work, untested). Verified on headless desktops only |
| **Existing outputs only** | niri, COSMIC, river, labwc, Wayfire and similar: `od-sender run --output <name>` streams an output you created yourself, if the compositor offers the screen-capture and virtual-pointer protocols `od-sender doctor` lists |
| **Not supported yet** | X11 sessions, Hyprland older than 0.55, Flatpak, SteamOS Gaming Mode, USB cable transport, HEVC, Apple Pencil pressure (mapped to a plain pointer), audio, mirror mode |

Prebuilt tarballs exist for **x86_64** and **aarch64**. On an unsupported
desktop `od-sender` exits with a message that names what is missing.

Mac receivers are encoded on the CPU at up to 4096x2304: expect noticeable CPU
use and about 60 ms of latency, against ~20 ms for a phone.

## Get started

1. [Install the sender](/docs/linux/install/) from the latest release, or
   build the Arch package.
2. Open the OpenDisplay app on your iPhone, iPad, Android device or Mac, on
   the same Wi-Fi.
3. Run `od-sender run` and move a window onto the new display. The
   [usage guide](/docs/linux/usage/) covers the details.

## Known issues

- **The cursor is part of the video on Hyprland.** It moves with video
  latency, and on a static screen it can lag until something else on the
  display changes. Hyprland's cursor-capture interface cannot deliver the
  cursor image yet, so the separate cursor channel stays off there. Use
  `--cursor off` to leave it out.
- **CPU encoding.** Hardware encoding (VA-API, V4L2) is not used yet, so
  encoding runs on the CPU with x264. A 5K iMac streamed at 4096x2304 costs
  noticeably more CPU and shows about 55-70 ms end to end, against ~20 ms for
  an iPhone.
- **Sway, KDE Plasma and GNOME are untested on real desktops.**
- **Android** is untested beyond a first session: touch, scroll, rotation,
  lock and quit are not checked yet.

A report that an "expected to work" or experimental setup works is just as
useful as a bug report; see [Reporting a problem](/docs/linux/troubleshooting/#reporting-a-problem).
