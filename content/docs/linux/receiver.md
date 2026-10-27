---
title: Linux receiver
nav: Receiver
description: Turn a Linux machine into an OpenDisplay display with od-receiver (beta), from the Arch package or the Flatpak bundle, windowed or fullscreen, with optional start on login.
order: 5
updated: 2026-10-22
---

`od-receiver` turns a Linux machine's screen into an OpenDisplay display: a
Mac or a Linux desktop extends onto it like onto an iPad. It is a **beta**.

It is a GTK 4 window that fills the screen once a sender connects, draws the
sender's cursor and sends pointer input back. It is tested windowed on Asahi
Linux / Hyprland (aarch64), at 24 ms end to end; other desktops and fullscreen
use are expected to work but untested.

Decoding runs in software through GStreamer (`gst-libav`); VA-API hardware
decoding (Intel/AMD, `gst-plugin-va`) is used when installed.

> Like the sender, **the stream is not encrypted**. Use it on a network you
> trust.

## Install on Arch / Omarchy

Build the package from the repository:

```sh
sudo pacman -S --needed base-devel git
git clone https://github.com/peetzweg/opendisplay
cd opendisplay/linux/packaging/arch/opendisplay-receiver
makepkg -si
```

To update, run `git pull && makepkg -si` in the same directory.

## Install the Flatpak (any distribution)

Download the Flatpak bundle for your machine (`uname -m` prints `x86_64` or
`aarch64`) from the
[latest release](https://github.com/peetzweg/opendisplay/releases/latest). Its
GNOME runtime comes from Flathub:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user od-receiver-x86_64.flatpak     # or od-receiver-aarch64.flatpak
flatpak run app.opendisplay.Receiver
```

## Run it

Start "OpenDisplay Receiver" from your app launcher, or `od-receiver` in a
terminal (`flatpak run app.opendisplay.Receiver` for the Flatpak). It
advertises itself on the network and waits for a sender.

- **From a Mac**: the Mac sender lists it like any other receiver.
- **From Linux**: run `od-sender run --to <its hostname>`; see
  [picking a receiver](/docs/linux/usage/#picking-a-receiver).

## Windowed or fullscreen

By default the window goes fullscreen on the first monitor once a sender
connects.

| Option | Default | |
|---|---|---|
| `--windowed` | off | Present in a normal window instead of fullscreen |
| `--output <name>` | first monitor | The monitor (connector name) to describe to the sender and to fullscreen on |
| `--name <name>` | hostname | The name it advertises on the network |
| `--listen <addr>` | `0.0.0.0:9000` | TCP address to listen on |

`od-receiver --help` lists the rest. A windowed receiver is fine for trying it
out; fullscreen shows the display at its real size.

## Start on login

The Arch package ships a `systemd --user` unit that runs the receiver in your
graphical session, fullscreen on the first monitor:

```sh
systemctl --user enable --now od-receiver
```

To change its arguments, for example to pick a monitor, run
`systemctl --user edit od-receiver`.

For the Flatpak, add `flatpak run app.opendisplay.Receiver` to your desktop's
autostart.

## Problems and reports

Report problems, and setups where it works, in
[#284](https://github.com/peetzweg/opendisplay/issues/284).
