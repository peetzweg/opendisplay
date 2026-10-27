---
title: Troubleshooting the Linux sender
nav: Troubleshooting
description: Fix common od-sender problems (no receiver found, a black display, taps that do nothing, high CPU), read doctor output and exit codes, report a bug, and uninstall.
order: 6
updated: 2026-10-22
---

## Start with doctor

```sh
od-sender doctor
```

`doctor` prints how it detected your desktop, the Hyprland version and
permission setting, the Wayland protocols it found, which encoders open, and
your config file. It changes nothing.

- Exit code **0**: `run` can work here.
- **2**: an unsupported desktop, or a config file that does not parse. The
  output says which.
- **1**: any other error, such as an unknown `--instance`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done |
| 1 | Error |
| 2 | Unsupported desktop, or a config file that does not parse |
| 3 | No receiver found |
| 4 | Several receivers found and no `--to` |

## "no receiver found" (exit 3)

- Is the OpenDisplay app **open and in the foreground** on the device?
- Is the device on the **same Wi-Fi** as this computer? Not a guest network,
  which usually blocks devices from seeing each other.
- On iPhone and iPad, Settings → Privacy & Security → Local Network must
  allow OpenDisplay.

`od-sender list --timeout 10` shows what answers. To skip discovery, connect
straight to the device's address:

```sh
od-sender run --to <device-ip>:9000
```

## "several receivers found" (exit 4)

Pick one with `--to <name>`, or set `to = "…"` in the
[config file](/docs/linux/configuration/).

## The receiver stays black

- On Hyprland, a black display with a "permission denied" caption means
  Hyprland's permission system is on; see
  [Hyprland permissions](/docs/linux/desktops/#hyprland-permissions).
- Otherwise, run the sender with debug logging and look for capture errors:

```sh
RUST_LOG=debug od-sender run --to <receiver>
```

## Taps do nothing

On KDE Plasma 6.7 and older, see
[KDE Plasma](/docs/linux/desktops/#kde-plasma): the sender needs its installed
desktop entry. Elsewhere, `od-sender doctor` shows whether a virtual-pointer
protocol was found.

## High CPU or lag

Encoding runs on the CPU. Lower `--max-fps` (for example 30) or
`--bitrate-mbps`, or use a smaller receiver. A Mac receiver at up to
4096x2304 costs noticeably more than a phone.

## The virtual display changed size after a theme switch

The sender puts it back within a second. If it keeps changing, it stops after
three tries and says so.

## A virtual display is left over

After a crash or `kill -9`, the virtual display stays behind on Hyprland and
Sway. Remove it with:

```sh
od-sender clean
```

On KDE Plasma 6.7 and older, `clean` also moves your other screens back if
the sender shifted them; or rearrange them in System Settings → Display.

## "another od-sender is already driving"

Only one sender can drive a receiver at a time. Stop the other one (or the
[login unit](/docs/linux/usage/#start-on-login),
`systemctl --user stop od-sender@<receiver>.service`) first.

## Reporting a problem

[Open an issue](https://github.com/peetzweg/opendisplay/issues/new/choose)
(or comment on [#299](https://github.com/peetzweg/opendisplay/issues/299))
with:

1. The output of `od-sender doctor`.
2. A debug log of the failing session:

   ```sh
   RUST_LOG=debug od-sender run --to <receiver> 2>&1 | tee od-sender.log
   ```

3. Your distribution, desktop and its version (`hyprctl version`,
   `sway --version`, `plasmashell --version` or `gnome-shell --version`), CPU
   architecture, and the receiver device and app version.

A report that an "expected to work" or experimental setup works is just as
useful. Linux receiver problems go to
[#284](https://github.com/peetzweg/opendisplay/issues/284).

## Uninstall

```sh
systemctl --user disable --now od-sender@iPhone.service   # if you enabled the login unit
od-sender clean                                          # remove a left-over virtual display
sudo pacman -R opendisplay-sender                        # Arch package; tarball: ./install.sh --uninstall
rm -r ~/.config/opendisplay                              # optional: your settings
```

For a tarball installed with `sudo ./install.sh --system`, uninstall with
`sudo ./install.sh --uninstall --system`.
