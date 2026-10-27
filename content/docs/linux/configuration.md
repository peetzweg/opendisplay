---
title: Configure the Linux sender
nav: Configuration
description: Every od-sender option and sender.toml key, with defaults and examples, including per-receiver overrides such as an iMac above the laptop on workspace 4.
order: 3
updated: 2026-10-22
---

## The config file

Defaults for `od-sender run`'s options, plus overrides per receiver, go in:

```text
~/.config/opendisplay/sender.toml
```

`$XDG_CONFIG_HOME` is honoured, and `--config <path>` uses another file. Keys
are the command-line option names without the leading `--`. The file is
optional; without it the built-in defaults apply.

When several settings apply, **the command line wins**, then the receiver's
own table, then the top of the file, then the built-in defaults.

Unknown keys and invalid values are errors: `run` refuses to start and `od-sender doctor` shows the problem, rather than a typo being silently
ignored. Run `od-sender doctor` after editing the file to check it.

## Options

Each key works at the top of `sender.toml` and as a `run` option.

| Key / option | Default | Values |
|---|---|---|
| `to` | the only receiver found | Receiver name (or part of it), id, or `host:port` |
| `position` | `auto-right` | `auto-right`, `auto-left`, `auto-up`, `auto-down`, or `x,y` |
| `scale` | `passthrough` | `passthrough`, `mac` or a number |
| `bitrate-mbps` | `20` | Video bitrate in Mbit/s |
| `max-fps` | `60` | Frame-rate cap |
| `encoder` | `auto` | `auto`, `v4l2m2m`, `x264` or `openh264` |
| `cursor` | `auto` | `auto`, `video` or `off` (`true` / `false` mean `auto` / `off`) |
| `capture` | `auto` | `auto`, `ext` or `wlr` |
| `workspace` | next free one | Workspace name or number (Hyprland and Sway) |

Only on the command line:

| Option | What it does |
|---|---|
| `--wait` | Keep looking until the receiver appears (the login unit uses it). Off by default |
| `--backend` | `hyprland`, `wlroots` (Sway), `kde`, `gnome`, or `adopt` with `--output`. Detected by default |
| `--output <name>` | Stream an existing output you created yourself instead of creating one (adopt mode) |
| `--config <path>` | Use another config file instead of `~/.config/opendisplay/sender.toml` |
| `--instance <id>` | Target one of several running Hyprland instances by index or signature, like `hyprctl -i` |

### to

The receiver `run` connects to when it gets no `--to`. It matches part of a
receiver's name or its full id (`od-sender list` shows both), or connects
straight to a `host:port`.

### position

Where the virtual display goes relative to your other monitors:
`auto-right`, `auto-left`, `auto-up`, `auto-down`, or explicit `x,y`
coordinates. On KDE Plasma, which does not allow negative coordinates,
`auto-left` and `auto-up` put the virtual display at the top left and shift
your other screens; see [KDE Plasma](/docs/linux/desktops/#kde-plasma).

### scale

- `passthrough`: the receiver's own scale (3 on most iPhones).
- `mac`: 2 for Retina-class screens, else 1, like the Mac sender.
- a number, such as `2`.

GNOME and Hyprland round to a scale they support (GNOME: an iPhone's 3 becomes
2; Hyprland: a Pixel's 2.625 becomes 2.667). If text is too small, try a
larger number.

### bitrate-mbps

The video bitrate, 20 Mbit/s by default. If encoding uses too much CPU or the
stream lags, lower it together with `max-fps`.

### max-fps

The frame-rate cap, 60 by default. Values above 60 apply only when the
receiver's decoder advertises them, and never above its panel rate. Lower it
(for example to 30) if encoding uses too much CPU.

### encoder

`auto` uses the first encoder that opens, in this order: `v4l2m2m` (a V4L2
hardware encoder through FFmpeg, where the machine has one), `x264`,
`openh264`. Naming one forces it. `od-sender doctor` lists which encoders
open on this machine.

### cursor

- `auto`: send the cursor separately when the receiver and desktop support
  it, which today means never on Hyprland.
- `video`: always paint the cursor into the video.
- `off`: leave the cursor out. `--no-cursor` on the command line is the same.

### capture

The screen-capture protocol on Hyprland and Sway: `auto`, `ext` or `wlr`.
`auto` uses `wlr` on Hyprland before 0.57, whose `ext` capture can crash when
a display disappears. Leave it on `auto` unless you are debugging.

### workspace

Show this workspace (name or number) on the virtual display, keeping your
focus where it is. Hyprland and Sway only; KDE Plasma and GNOME ignore it with
a warning. Without it, the next free workspace is used.

## Per-receiver overrides

A `[receiver."…"]` table overrides `position`, `scale`, `bitrate-mbps` and
`workspace` for one receiver. Its name is matched against the receiver's id
(shown by `od-sender list`; case does not matter), then its network name,
then the device name it reports.

```toml
[receiver."3F2A9C1E-..."]
position = "auto-left"
scale = 2
workspace = "phone"
```

## Example: iMac above the laptop on workspace 4

A laptop with a spare iMac behind it, running OpenDisplay Receiver. The iMac
should sit **above** the laptop screen and always show **workspace 4**, while
an iPhone keeps the defaults:

```toml
# ~/.config/opendisplay/sender.toml

[receiver."iMac"]
position = "auto-up"
workspace = "4"
```

Then:

```sh
od-sender run --to iMac
```

The virtual display appears above your laptop screen and shows workspace 4;
move the pointer up off the top edge to reach it. On Hyprland and Sway, the
iMac shows workspace 4 and your focus stays where it was. Add
`to = "iMac"` at the top of the file to make plain `od-sender run` connect to
it, or start it on login with
`systemctl --user enable --now od-sender@iMac.service`.

A Mac receiver is encoded on the CPU at up to 4096x2304, so expect noticeable
CPU use and about 60 ms of latency. If that is too much, set a lower
`bitrate-mbps` in the iMac's table or a lower `max-fps` at the top of the
file.

## Full example

```toml
to = "iPhone"            # used when run gets no --to
position = "auto-right"
scale = "passthrough"    # "passthrough", "mac" or a number
bitrate-mbps = 20
max-fps = 60
encoder = "auto"         # "auto", "v4l2m2m", "x264" or "openh264"
cursor = "auto"          # "auto", "video" or "off" (true/false: auto/off)
capture = "auto"         # "auto", "ext" or "wlr"
workspace = "8"          # Hyprland/Sway: show workspace 8 on the virtual display

# Overrides for one receiver: position, scale, bitrate-mbps and workspace.
[receiver."3F2A9C1E-..."]
position = "auto-left"
scale = 2
workspace = "phone"

[receiver."iMac"]
position = "auto-up"
workspace = "4"
```

To remove your settings, delete `~/.config/opendisplay`.
