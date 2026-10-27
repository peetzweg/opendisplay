---
title: Third-party Linux senders for OpenDisplay
nav: Linux senders
description: Community Linux senders that extend a Linux desktop onto an iPhone or iPad running the official OpenDisplay app, including opendisplay-x11 for X11 desktops over a USB cable and opendisplay-linux for KDE Plasma and Hyprland.
order: 2
updated: 2026-10-23
---

## Official sender first

OpenDisplay has its own [Linux sender (beta)](/docs/linux/), `od-sender`, for
Wayland desktops: Hyprland, plus experimental Sway, KDE Plasma and GNOME
backends. Start there on Wayland.

Two things the official sender does **not** do yet are where the community
projects below help:

- **X11 sessions** (Linux Mint Cinnamon, Xfce, MATE, Ubuntu on Xorg, …):
  use [opendisplay-x11](#opendisplay-x11-for-x11-desktops).
- **A USB cable** instead of Wi-Fi: both projects below can use one.

Both work with the **unmodified** OpenDisplay app on the iPhone or iPad from
the [App Store](https://apps.apple.com/app/id6780264891).

> These are community projects, not official builds. See
> [Third-party apps](/docs/third-party/) for what that means.

## opendisplay-x11 for X11 desktops

[cray2015/opendisplay-x11](https://github.com/cray2015/opendisplay-x11)
(`odx11`) extends an **X11** desktop onto an iPad over a **USB cable**. Plug in
the cable, open the OpenDisplay app, and the desktop extends onto the iPad;
touch, drag, long-press for right-click and two-finger scroll work.

- **Status:** alpha, used daily by its author on an HP EliteDesk 800 G3
  (Intel HD 530) with Linux Mint 22.3 Cinnamon and an iPad Air (5th
  generation).
- **Needs a free video port.** X11 cannot create a monitor out of nothing, so
  odx11 turns an **empty HDMI socket**, or a DisplayPort socket that accepts
  HDMI adapters (DP++), into the iPad's monitor. It does not work if every
  video port already has a monitor, with only USB-C/Thunderbolt free (most
  likely), or with NVIDIA's proprietary driver. Its README explains why and
  how to check.
- **Needs:** an X11 session (not Wayland), Linux Mint 22 or Ubuntu 24.04 or
  newer with a systemd user session, VA-API H.264 encoding (tested on Intel
  `i915`; AMD untested), a USB data cable, and an iPad that is trusted and
  unlocked.
- **How it works:** the iPad's monitor is the panel size divided by 1.5 so
  text stays readable; video is encoded on the GPU; the iPad draws the cursor
  itself from position messages; capture pauses when nothing on the iPad's
  monitor changes (about 1 % of a CPU core idle).
- **Install:** download the `.deb` from its
  [releases](https://github.com/cray2015/opendisplay-x11/releases), open it
  with the package installer, then open **OpenDisplay for X11** and turn it
  on. It starts with the desktop from then on. There is no update channel yet.
- **Licence:** GPL-3.0-or-later. Its
  [TRUST.md](https://github.com/cray2015/opendisplay-x11/blob/main/TRUST.md)
  describes what it can access and how to verify a release.

## opendisplay-linux for KDE Plasma and Hyprland

[tixwho/opendisplay-linux](https://github.com/tixwho/opendisplay-linux) is a
fork of this repository with a Linux sender for **Wayland**.

- **Desktops:** KDE Plasma (through `xdg-desktop-portal-kde` and KScreen) and
  Hyprland (through `xdg-desktop-portal-hyprland` and headless outputs). Other
  compositors and X11 are not supported.
- **Connection:** Wi-Fi with Avahi discovery, or USB through `usbmuxd`.
- **Install:** build with CMake, or build its Arch package with `makepkg`;
  see its [Linux guide](https://github.com/tixwho/opendisplay-linux/blob/main/Linux/README.md).
  Hardware encoding needs the VA-API driver for your GPU.

## Compared

| | Official `od-sender` | opendisplay-x11 | opendisplay-linux |
|---|---|---|---|
| Session | Wayland | X11 | Wayland |
| Desktops | Hyprland; Sway, KDE Plasma, GNOME experimental | Any X11 desktop | KDE Plasma, Hyprland |
| Connection | Wi-Fi | USB cable | Wi-Fi, USB |
| Receivers | iPhone, iPad, Android, Mac | iPad | iPhone, iPad |
| Extra hardware | None | A free HDMI or DP++ port | None |
| Install | [Release builds](/docs/linux/install/) | `.deb` | Build from source |
| Status | Beta | Alpha | Community fork |
