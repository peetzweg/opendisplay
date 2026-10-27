---
title: Use the Linux sender
nav: Usage
description: First run of od-sender, picking a receiver, using several devices, putting a workspace on the receiver, and starting the OpenDisplay Linux sender on login.
order: 2
updated: 2026-10-22
---

## First run

Open the OpenDisplay app on the receiver, **in the foreground and on the same
Wi-Fi** as your computer. Then:

```sh
od-sender doctor              # what od-sender will use on this desktop
od-sender list                # receivers on the network: name, address, protocol version, id
od-sender connect iMac        # connect to a receiver by name (case doesn't matter)
od-sender connect             # no name: the only receiver, or pick from a list
od-sender disconnect iMac     # from any terminal; no name disconnects all
```

`od-sender connect <receiver>` and `od-sender run --to <receiver>` are the
same command. The connection lasts as long as the command runs: **Ctrl+C**
in its terminal, or `od-sender disconnect` from any other, ends it and removes
the virtual display. Running `connect` again reconnects.

If several receivers are on the network and you name none, `connect` asks
which one to use. A name that matches nothing lists the receivers that did
answer. Scripts and agents get no prompt: `connect` then exits with code 4
(several receivers) or 3 (none matching) and prints the list, and
`od-sender list --json` returns the receivers as JSON (`name`, `addr`, `id`,
`pv`).

`od-sender` detects your desktop (Hyprland, Sway, KDE Plasma or GNOME) and
creates the virtual display there, by default to the right of your current
monitors. Once it is up, `run` prints one line such as:

```text
Extending onto iPhone: 852x393 logical at 3x (od-3f9a1c, right of your other displays). Ctrl+C to stop.
```

Move a window onto the new display by dragging it there. On Omarchy,
Super+Shift+Right moves the focused window to the display on the right.

Taps on the receiver click, and two-finger scrolls scroll. Rotate the device
and the virtual display is rebuilt in portrait.

## Picking a receiver

`run` looks for receivers over Bonjour/mDNS for up to 10 seconds.

- Without `--to`, it uses the only receiver it finds and says so.
- With several receivers on the network, it lists them and asks you to pick
  one with `--to` (or `to = "…"` in the
  [config file](/docs/linux/configuration/)). It exits with code 4.
- `--to` matches part of a receiver's name or its full id, or connects
  straight to a `host:port`, which skips discovery.
- `--wait` keeps looking until the receiver appears.

```sh
od-sender run --to iPhone           # part of the name
od-sender run --to 192.168.1.42:9000  # an address, no discovery
od-sender run --to iMac --wait      # wait until the iMac shows up
```

## Placing the display

`--position` decides where the virtual display goes relative to your other
monitors: `auto-right` (the default), `auto-left`, `auto-up`, `auto-down`, or
explicit `x,y` coordinates.

```sh
od-sender run --to iMac --position auto-up
```

`--scale` sets how large things are drawn: `passthrough` (the default, the
receiver's own scale, 3 on most iPhones), `mac` (2 for Retina-class screens,
else 1, like the Mac sender) or a number. If text is too small, try a larger
number. All options and their defaults are listed in
[Configuration](/docs/linux/configuration/#options).

## Workspaces

On **Hyprland and Sway**, `--workspace` shows a workspace (name or number) on
the virtual display, keeping your focus where it is. Without it, the sender
uses the next free workspace.

```sh
od-sender run --to iPhone --workspace 8
```

KDE Plasma and GNOME ignore `--workspace` with a warning.

## Several devices

If you use more than one receiver, say an iPhone on the go and an iMac at
your desk, give each its own settings in the
[config file](/docs/linux/configuration/#per-receiver-overrides): position,
scale, bitrate and workspace per receiver. `od-sender run --to iMac` then
picks up the iMac's settings.

One `od-sender run` drives one receiver with one virtual display. For two
receivers at once, start one sender per receiver, each with its own `--to`
(or one [login unit](#start-on-login) instance each). Driving several
receivers at the same time is not part of the tested beta setup yet; please
report how it goes in [#299](https://github.com/peetzweg/opendisplay/issues/299).

Only one sender can drive a receiver at a time. A second `run` for the same
receiver exits with `another od-sender (pid N) is already driving …`.

## Start on login

The tarball and the Arch package install a `systemd --user` unit,
`od-sender@.service`. Enable it with the receiver as the instance name:

```sh
systemctl --user enable --now od-sender@iPhone.service
```

The instance name is passed to `od-sender run --to … --wait`, so it can be a
receiver name, id or address, and the unit waits quietly while the device is
away. Enable one instance per receiver.

The unit starts with your graphical session (`graphical-session.target`, as on
Omarchy). On a Hyprland started without that target, add this to your
Hyprland config instead:

```text
exec-once = od-sender run --to iPhone --wait
```

## Reconnects and recovery

- If the Wi-Fi drops, the sender reconnects, waiting a little longer after
  each failed attempt (up to 10 seconds).
- If the virtual display is removed or reconfigured from under it
  (`hyprctl output remove`, or `hyprctl reload` from a theme switch), the
  sender restores it; after three losses within a minute it gives up.

## Stopping

Stop the sender with Ctrl+C, `SIGTERM` (what `systemctl --user stop` sends) or
`SIGHUP` (closing its terminal): each removes the virtual display before
exiting.

After a crash or `kill -9`, the virtual display stays behind on Hyprland and
Sway. `od-sender clean` removes it, and the next `run` for the same receiver
reuses it. KDE Plasma and GNOME remove it themselves.

```sh
od-sender clean               # remove virtual displays left behind by a crashed sender
```

## Several Hyprland instances

`--instance <index|signature>` (on any command) targets one of several running
Hyprland instances, like `hyprctl -i`; `od-sender doctor` lists them.
