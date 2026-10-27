---
title: Linux desktop notes
nav: Desktops
description: How the OpenDisplay Linux sender works on Hyprland, Sway, KDE Plasma and GNOME, what each desktop needs, and how to stream an existing output on other compositors.
order: 4
updated: 2026-10-22
---

`od-sender` detects your desktop and creates the virtual display with that
desktop's own interfaces; `--backend` overrides the choice. `od-sender doctor`
shows what it detected and which protocols it found.

| Desktop | Status | Virtual display |
|---|---|---|
| Hyprland 0.55+ | Tested on 0.56 (Omarchy, Asahi) | Created and removed by the sender |
| Sway 1.10+ | Experimental, verified headless only | Created and removed by the sender |
| KDE Plasma 6.8+ | Experimental, verified headless only | Created by the sender, removed by KWin |
| GNOME 50+ | Experimental, verified headless only | Created by the sender, removed by Mutter |
| niri, COSMIC, river, labwc, Wayfire… | Existing outputs only | You create it, `--output <name>` |

X11 sessions are not supported.

## Hyprland

Hyprland 0.55 or newer; tested on 0.56 on Omarchy. On Omarchy, move a window
to the virtual display with Super+Shift+Right (or drag it), and
`--workspace 8` shows workspace 8 on the receiver instead.

The cursor is painted into the video on Hyprland, because its cursor-capture
interface cannot deliver the cursor image yet. It moves with video latency;
`--cursor off` leaves it out.

### Hyprland permissions

Omarchy does not enable Hyprland's permission system by default, and then
nothing needs configuring. If you turned on `ecosystem:enforce_permissions`,
Hyprland does not refuse an unapproved screen capture: it hands the client
black frames with a "permission denied" caption, so **the receiver shows a
black display**. Either allow the capture in the dialog Hyprland shows, or add
a rule for `od-sender` to `~/.config/hypr/hyprland.lua`:

```lua
hl.permission("/usr/bin/od-sender", "screencopy", "allow")
```

The first argument is a regex for the binary's path; use your own path for a
source build or the tarball (for example `".*/od-sender"`). Hyprland reads
permission rules only at startup, so restart Hyprland after adding it. Touch
and scroll go through the virtual pointer protocol, which Hyprland does not
gate. Run `od-sender doctor` to see whether permissions are enforced on your
session.

### Start on login without systemd

The [login unit](/docs/linux/usage/#start-on-login) starts with
`graphical-session.target`, as on Omarchy. On a Hyprland started without that
target, add this to your Hyprland config instead:

```text
exec-once = od-sender run --to iPhone --wait
```

## Sway

Sway 1.10 or newer, **experimental**. `od-sender` creates a headless output
with `swaymsg create_output`, sizes and places it through the
output-management protocol, and removes it on exit; `od-sender clean` removes
one left by a crash. `--workspace` works like on Hyprland.

## KDE Plasma

KDE Plasma 6.8 or newer, **experimental**, lets `od-sender` create a virtual
display and move the pointer with no dialog.

**Plasma 6.7 and older** grant that only to a program named by an installed
desktop entry: KWin compares the running binary with the entry's `Exec=`
path. So on 6.7 and older:

1. Install with the [Arch package or the tarball's
   `install.sh`](/docs/linux/install/) (both install `od-sender.desktop`
   pointing at the installed binary). A binary run from elsewhere (a source
   build in `target/`) is refused.
2. Log out and in, so KWin sees the entry.
3. `od-sender doctor` should list `zkde_screencast_unstable_v1` and
   `org_kde_kwin_fake_input`.

This follows KWin 6.7's source and has not been tried on a real 6.7 desktop.

Scale and position are set like on the other desktops. Plasma does not allow
displays at negative coordinates, so `--position auto-left` or `auto-up` puts
the virtual display at the top left and shifts your other screens right or
down; they move back when it goes away. KWin 6.8 also moves them back by
itself if the sender crashes; on older Plasma run `od-sender clean`, or
rearrange them in System Settings → Display.

`--workspace` is ignored on KDE Plasma, with a warning.

### SteamOS (Desktop Mode)

Untested. The root filesystem is read-only, so use the tarball's
`./install.sh` (into `~/.local/bin`), log out and in, and check
`od-sender doctor`. Gaming Mode is not supported.

## GNOME

GNOME 50 or newer (Mutter 50), **experimental**: verified on a headless Mutter
in CI, so please report whether it holds on your desktop. Older GNOME may
work, untested.

`od-sender` uses Mutter's own screen-cast and remote-desktop interfaces, so
there is no sharing dialog. To set the scale and position it applies a
temporary display configuration that keeps all your other monitors exactly as
they are, and GNOME restores your layout when the virtual display goes away.
GNOME rounds the scale to one it supports (an iPhone's 3 becomes 2).

`--workspace` is ignored on GNOME, with a warning. Not available from a
Flatpak.

## Other compositors: stream an existing output

On niri, COSMIC, river, labwc, Wayfire and similar, `od-sender` cannot create
the virtual display itself. Create an output with your compositor's own tools,
then stream it:

```sh
od-sender run --output <name> --to iPhone
```

This works if the compositor offers the screen-capture and virtual-pointer
protocols that `od-sender doctor` lists. It is unchecked per compositor;
reports are welcome in [#299](https://github.com/peetzweg/opendisplay/issues/299).
