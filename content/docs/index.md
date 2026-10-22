---
title: OpenDisplay documentation
nav: Docs
description: How to set up and use OpenDisplay, the free, open-source way to turn a spare iPhone, iPad, Mac, Android device or Linux machine into a second monitor.
order: 0
updated: 2026-10-22
---

## What OpenDisplay is

OpenDisplay turns a device you already own into a real extended display: your
computer gains a new monitor, and you drag windows onto it like onto any other
screen. It is a free, open-source alternative to Apple Sidecar, Duet Display
and Luna Display, licensed under GPL-3.0. There is no account, no server and
no telemetry: one direct connection between the two devices.

It always takes **two apps**:

- a **sender** on the computer whose desktop gets extended. It creates a
  virtual display, captures it, encodes it as H.264 and streams it;
- a **receiver** on the device that shows the display. It decodes the stream
  and sends taps and scrolls back as pointer input.

All senders and receivers speak the same
[protocol](https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md), so
any receiver works with any sender.

## Platforms

| | Sender | Receiver |
|---|---|---|
| **macOS** | macOS 14+, download or Homebrew | OpenDisplay Receiver, macOS 12+ |
| **iPhone and iPad** | | App Store, iOS / iPadOS 15+ |
| **Android** | | Public beta on Google Play, Android 7.0+, over Wi-Fi |
| **Linux** | Beta: [Linux sender](/docs/linux/) | Beta: [Linux receiver](/docs/linux/receiver/) |

The Mac apps and the iPhone, iPad and Android apps are covered on the
[home page](/), with download links and the FAQ. The Mac apps are also
on the [latest release](https://github.com/peetzweg/opendisplay/releases/latest)
and in Homebrew:

```sh
brew install --cask opendisplay           # the sender
brew install --cask opendisplay-receiver  # a Mac that should be the display
```

## Linux

The Linux sender and receiver are in beta. Start with the
[Linux overview](/docs/linux/), which lists the tested and experimental
desktops, then:

- [Install the sender](/docs/linux/install/)
- [Use it](/docs/linux/usage/): first run, picking a receiver, several devices,
  workspaces, start on login
- [Configure it](/docs/linux/configuration/) with `sender.toml`
- [Notes per desktop](/docs/linux/desktops/): Hyprland, Sway, KDE Plasma, GNOME
- [Use a Linux machine as the display](/docs/linux/receiver/)
- [Troubleshooting](/docs/linux/troubleshooting/)

## Help and feedback

Questions, bugs and reports that something works go to
[GitHub issues](https://github.com/peetzweg/opendisplay/issues). The source,
including these pages, is on
[GitHub](https://github.com/peetzweg/opendisplay).
