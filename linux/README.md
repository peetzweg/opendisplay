# OpenDisplay Linux sender (beta)

> **Docs:** the same guide, split into pages (install, usage, configuration,
> desktops, receiver, troubleshooting), is at
> **[opendisplay.app/docs/linux](https://opendisplay.app/docs/linux/)**.

The OpenDisplay Linux sender (`od-sender`) extends a Linux desktop onto an
OpenDisplay receiver: an iPhone, iPad, Android device or spare Mac running the
OpenDisplay app. It creates a **virtual display** on your desktop sized for
the receiver (an "output", in compositor terms), captures it, encodes it as
H.264 and streams it over Wi-Fi. Taps and two-finger scrolls on the receiver
come back as pointer input, and rotating the device rebuilds the virtual
display in portrait.

It speaks the same protocol as the Mac sender ([PROTOCOL.md](../PROTOCOL.md)),
so the receivers from the App Store, Google Play and the releases page work
unchanged. There is no account, no server and no telemetry: one connection
between the two devices. **The stream is not encrypted**, so use it on a
network you trust.

Video is encoded on the CPU for now (x264); hardware encoding (VA-API) is
planned.

The other direction, a Linux machine as the display, is the
[Linux receiver](#linux-receiver-beta), also in beta.

## Supported setups

Tested on **Omarchy / Hyprland 0.56 on Apple silicon (Asahi Linux)**; x86_64
is expected to work and needs testers. Sway, KDE Plasma and GNOME have their
own backends, marked **experimental**: each passes an automated test on a
headless copy of that desktop, but none has run on a real desktop session yet.
Reports are very welcome ([#299](https://github.com/peetzweg/opendisplay/issues/299)).

| | Setup |
|---|---|
| **Tested** | Arch / Omarchy, Hyprland 0.56, aarch64 (Asahi Linux on an M1 Pro), CPU encoding. Receivers: iPhone (App Store), Mac receiver app (Intel iMac) |
| **Expected to work** | Arch / Omarchy on x86_64. Any distro with Hyprland 0.55+. iPad and Android (Google Play beta) as receivers: Android streamed fine in a first session (Pixel 10a, 53 fps, 33 ms), but touch, scroll, rotation, lock and quit are not checked yet |
| **Experimental** | **Sway 1.10+**, **KDE Plasma 6.8+** (6.7 and older with the desktop entry in place, see [KDE Plasma](#kde-plasma)), **GNOME 50+** (older GNOME may work, untested). Verified on headless desktops only |
| **Existing outputs only** | niri, COSMIC, river, labwc, Wayfire and similar: `od-sender run --output <name>` streams an output you created yourself, if the compositor offers the screen-capture and virtual-pointer protocols `od-sender doctor` lists |
| **Not supported yet** | X11 sessions, Hyprland older than 0.55, Flatpak, SteamOS Gaming Mode, HEVC, Apple Pencil pressure (mapped to a plain pointer), audio, mirror mode |

On an unsupported desktop `od-sender` exits with a message that names what is
missing.

Mac receivers are encoded on the CPU at up to 4096x2304: expect noticeable CPU
use and about 60 ms of latency, against ~20 ms for a phone.

## Install

Two ways, both from the [latest OpenDisplay release](https://github.com/peetzweg/opendisplay/releases/latest). Linux ships in
every release, with the same version number as the Mac and iOS apps.

### Prebuilt tarball (any distribution)

The `x86_64` and `aarch64` tarballs link a minimal FFmpeg and x264
statically, so no FFmpeg install is needed; they run on glibc 2.38 or newer
on x86_64 (Ubuntu 24.04, Debian 13, Fedora 39 and later) and glibc 2.39 or
newer on aarch64 (Ubuntu 24.04, Debian 13, Fedora 40 and later), and need
PipeWire's library, `libpipewire-0.3`, which every current desktop already
has. Licence texts for the bundled FFmpeg, x264, OpenH264 and Rust crates
are in `THIRD-PARTY-LICENSES.txt`. Download the one for your machine
(`uname -m`), unpack it and run the installer:

```sh
tar xf od-sender-$(uname -m)-unknown-linux-gnu.tar.gz && cd od-sender-$(uname -m)-unknown-linux-gnu
./install.sh                 # into ~/.local/bin, with the desktop entry and systemd --user unit
sudo ./install.sh --system   # or into /usr/local for every user
./install.sh --uninstall     # removes them again (add --system for /usr/local)
```

`install.sh` points the desktop entry and the unit at the installed binary,
which KDE Plasma 6.7 and older need (see [KDE Plasma](#kde-plasma)). If
`~/.local/bin` did not exist before, log out and in so it is on your `PATH`.
To update, install the next release's tarball the same way.

### Arch / Omarchy: build the package

The repository carries the Arch package's `PKGBUILD`. It builds the release
tag against your system FFmpeg and installs `/usr/bin/od-sender`, a desktop
entry (it shows up in the Omarchy menu and opens in a terminal) and a
`systemd --user` unit, `od-sender@.service`, for starting it on login:

```sh
sudo pacman -S --needed base-devel git
git clone https://github.com/peetzweg/opendisplay
cd opendisplay/linux/packaging/arch/opendisplay-sender
makepkg -si
```

`makepkg` pulls in Rust and clang as build dependencies; the build and its
tests take about 2.5 minutes on an 8-core M1 Pro, longer on smaller
machines. To update, run `git pull && makepkg -si` in the same directory.
(An AUR package follows once AUR registration reopens.)

### From source

You need Rust (stable), FFmpeg and PipeWire with their headers, `pkgconf` and
`clang` (for the FFmpeg bindings); on x86_64 also `nasm`.

```sh
# Arch
sudo pacman -S --needed rust ffmpeg libpipewire pkgconf clang nasm
# Fedora (ffmpeg-free has no libx264, so the slower built-in OpenH264 encoder
# is used; RPM Fusion's ffmpeg-devel brings x264)
sudo dnf install rust cargo clang pkgconf-pkg-config nasm ffmpeg-free-devel pipewire-devel
# Debian / Ubuntu
sudo apt install rustup clang pkg-config nasm libavcodec-dev libavformat-dev \
  libavutil-dev libswscale-dev libpipewire-0.3-dev && rustup default stable

git clone https://github.com/peetzweg/opendisplay
cd opendisplay/linux
cargo build --release -p od-sender
./target/release/od-sender doctor
```

## Usage

Open the OpenDisplay app on the receiver, in the foreground and on the same
Wi-Fi as your computer. Receivers: iPhone and iPad from the App Store,
Android from the Google Play beta, Mac: OpenDisplay Receiver from the
[releases page](https://github.com/peetzweg/opendisplay/releases/latest).
Then:

```sh
od-sender doctor              # what od-sender will use on this desktop
od-sender list                # receivers on the network: name, address, protocol version, id
od-sender run                 # the only receiver on the network
od-sender run --to iPhone     # or pick one by name, receiver id, or address (host:port)
od-sender run --usb           # connect to an iPhone/iPad over USB cable (usbmuxd)
od-sender clean               # remove virtual displays left behind by a crashed sender
```

`run` looks for receivers over Bonjour/mDNS for up to 10 seconds. Without
`--to` it uses the only receiver it finds and says so; with several on the
network it lists them and asks you to pick one with `--to` (or `to = "…"` in
the [config file](#configuration)). `--to` matches part of a receiver's name
or its full id, or connects straight to a `host:port`. `--wait` keeps looking
until the receiver appears.

Bonjour does not cross VPNs. When it finds nothing and
[Tailscale](https://tailscale.com) is running, `run` and `list` also try the
online Tailscale peers on port 9000 and use the ones that answer as an
OpenDisplay receiver, named as `tailscale status` shows them. This adds about
a second, only when Bonjour found nothing; `tailscale = false` in the config
file turns it off. `run --wait` does not try Tailscale: give it the address
(`--to <tailscale-ip>:9000`).

`od-sender` detects your desktop (Hyprland, Sway, KDE Plasma or GNOME) and
creates the virtual display there, by default to the right of your current
monitors; `--backend` overrides the choice. Once it is up, `run` prints one
line such as `Extending onto iPhone: 852x393 logical at 3x (od-3f9a1c, right
of your other displays). Ctrl+C to stop.` On Omarchy, move a window there
with Super+Shift+Right (or drag it); `--workspace 8` shows workspace 8 on the
receiver instead.

If the Wi-Fi drops, the sender reconnects, waiting a little longer after each
failed attempt (up to 10 seconds). If the virtual display is removed or
reconfigured from under it (`hyprctl output remove`, `hyprctl reload` from a
theme switch), the sender restores it; after three losses within a minute it
gives up.

Stop the sender with Ctrl+C, `SIGTERM` (what `systemctl --user stop` sends)
or `SIGHUP` (closing its terminal): each removes the virtual display before
exiting. After a crash or `kill -9` the virtual display stays behind on
Hyprland and Sway; `od-sender clean` removes it, and the next `run` for the
same receiver reuses it. KDE Plasma and GNOME remove it themselves.

Only one sender can drive a receiver at a time. A second `run` for the same
receiver exits with `another od-sender (pid N) is already driving …`.

Useful `run` options:

| Option | Default | |
|---|---|---|
| `--to` | the only receiver found | Receiver name, id, or `host:port` |
| `--wait` | off | Keep looking until the receiver appears (the login unit uses it) |
| `--position` | `auto-right` | Where the virtual display goes: `auto-right`, `auto-left`, `auto-up`, `auto-down`, or `x,y` |
| `--scale` | `passthrough` | `passthrough` (the receiver's own, 3 on most iPhones), `mac` (2 for Retina-class screens, else 1, like the Mac sender) or a number. GNOME and Hyprland round to a scale they support (GNOME: an iPhone's 3 becomes 2; Hyprland: a Pixel's 2.625 becomes 2.667). If text is too small, try a larger number |
| `--bitrate-mbps` | `20` | Video bitrate |
| `--max-fps` | 60 | Frame-rate cap; above 60 only when the receiver's decoder advertises it, and never above its panel rate |
| `--encoder` | `auto` | `auto`, `v4l2m2m`, `x264` or `openh264` |
| `--cursor` | `auto` | `auto`, `video` (always paint the cursor into the video) or `off`; `--no-cursor` is `off`. `auto` sends the cursor separately when the receiver and desktop support it, which today means never on Hyprland |
| `--capture` | `auto` | Screen-capture protocol on Hyprland and Sway: `auto`, `ext` or `wlr`. `auto` uses `wlr` on Hyprland before 0.57, whose `ext` capture can crash when a display disappears |
| `--workspace` | next free one | Show this workspace (name or number) on the virtual display, keeping your focus where it is. Hyprland and Sway; ignored with a warning on KDE Plasma and GNOME |
| `--backend` | detected | `hyprland`, `wlroots` (Sway), `kde`, `gnome`, or `adopt` with `--output <name>` |

`--instance <index|signature>` (any command) targets one of several running
Hyprland instances, like `hyprctl -i`; `od-sender doctor` lists them.

Exit codes: 0 done, 1 error, 2 unsupported desktop or a config file that does
not parse, 3 no receiver found, 4 several receivers and no `--to`.

### `doctor`

`od-sender doctor` prints how it detected your desktop, the Hyprland version
and permission setting, the Wayland protocols it found, which encoders open,
and your config file. It changes nothing. Exit code 0 means `run` can work
here; 2 means an unsupported desktop or a config file that does not parse
(the output says which); 1 is any other error, such as an unknown
`--instance`.

### Configuration

Defaults for `run`'s options, plus overrides per receiver, go in
`~/.config/opendisplay/sender.toml` (`$XDG_CONFIG_HOME` is honoured; pass
`--config <path>` to use another file). Keys are the option names:

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
tailscale = true         # false: never try Tailscale peers when Bonjour finds nothing

# Overrides for one receiver: position, scale, bitrate-mbps and workspace.
[receiver."3F2A9C1E-..."]
position = "auto-left"
scale = 2
workspace = "phone"
```

A `[receiver."…"]` table is matched against the receiver's id (shown by
`od-sender list`, case does not matter), then its network name, then the
device name it reports. When several settings apply, the command line wins,
then the receiver's table, then the top of the file, then the built-in
defaults.

Unknown keys and invalid values are errors: `run` refuses to start and
`od-sender doctor` shows the problem, rather than a typo being silently
ignored.

### Start on login

```sh
systemctl --user enable --now od-sender@iPhone.service
```

The instance name is passed to `od-sender run --to … --wait`, so it can be a
receiver name, id or address, and the unit waits quietly while the device is
away. It starts with your graphical session (`graphical-session.target`, as on
Omarchy); on a Hyprland started without that target, use
`exec-once = od-sender run --to iPhone --wait` instead.

## Desktop notes

### Sway

Sway 1.10 or newer. `od-sender` creates a headless output with
`swaymsg create_output`, sizes and places it through the output-management
protocol, and removes it on exit; `od-sender clean` removes one left by a
crash.

### KDE Plasma

KDE Plasma 6.8 or newer lets `od-sender` create a virtual display and move
the pointer with no dialog. **Plasma 6.7 and older** grant that only to a
program named by an installed desktop entry: KWin compares the running binary
with the entry's `Exec=` path. So on 6.7 and older:

1. Install with the Arch package or the tarball's `install.sh` (both install
   `od-sender.desktop` pointing at the installed binary). A binary run from
   elsewhere (a source build in `target/`) is refused.
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

**SteamOS (Desktop Mode)**, untested: the root filesystem is read-only, so use
the tarball's `./install.sh` (into `~/.local/bin`), log out and in, and check
`od-sender doctor`. Gaming Mode is not supported.

### GNOME

GNOME 50 or newer (Mutter 50); verified on a headless Mutter in CI, so please
report whether it holds on your desktop. `od-sender` uses Mutter's own
screen-cast and remote-desktop interfaces, so there is no sharing dialog. To
set the scale and position it applies a temporary display configuration that
keeps all your other monitors exactly as they are, and GNOME restores your
layout when the virtual display goes away. Not available from a Flatpak.

### Hyprland permissions

Omarchy does not enable Hyprland's permission system by default, and then
nothing needs configuring. If you turned on `ecosystem:enforce_permissions`,
Hyprland does not refuse an unapproved screen capture: it hands the client
black frames with a "permission denied" caption, so the receiver shows a black
display. Either allow the capture in the dialog Hyprland shows, or add a rule
for `od-sender` to `~/.config/hypr/hyprland.lua`:

```lua
hl.permission("/usr/bin/od-sender", "screencopy", "allow")
```

The first argument is a regex for the binary's path; use your own path for a
source build or the tarball (for example `".*/od-sender"`). Hyprland reads
permission rules only at startup, so restart Hyprland after adding it. Touch
and scroll go through the virtual pointer protocol, which Hyprland does not
gate. Run `od-sender doctor` to see whether permissions are enforced on your
session.

## Troubleshooting

* **"no receiver found"** (exit 3): is the OpenDisplay app open and in the
  foreground on the device, on the same Wi-Fi as this computer (not a guest
  network, which usually blocks devices from seeing each other)? On iPhone and
  iPad, Settings → Privacy & Security → Local Network must allow OpenDisplay.
  `od-sender list --timeout 10` shows what answers; `od-sender run --to
  <device-ip>:9000` skips discovery. Over a VPN, Bonjour does not reach the
  device: Tailscale peers are tried automatically (`RUST_LOG=debug` shows
  each probe); with another VPN, use `--to <vpn-ip>:9000`.
* **"several receivers found"** (exit 4): pick one with `--to <name>`, or set
  `to = "…"` in the config file.
* **The receiver stays black**: on Hyprland, see
  [Hyprland permissions](#hyprland-permissions). Otherwise run
  `RUST_LOG=debug od-sender run …` and look for capture errors.
* **Taps do nothing**: on KDE Plasma 6.7 and older, see
  [KDE Plasma](#kde-plasma); elsewhere, `od-sender doctor` shows whether a
  virtual-pointer protocol was found.
* **High CPU or lag**: encoding runs on the CPU. Lower `--max-fps` (for
  example 30) or `--bitrate-mbps`, or use a smaller receiver.
* **The virtual display changed size after a theme switch**: the sender puts
  it back within a second; if it keeps changing, it stops after three tries
  and says so.

## Uninstall

```sh
systemctl --user disable --now od-sender@iPhone.service   # if you enabled the login unit
od-sender clean                                          # remove a left-over virtual display
sudo pacman -R opendisplay-sender                        # Arch package; tarball: ./install.sh --uninstall
rm -r ~/.config/opendisplay                              # optional: your settings
```

## Known issues

* **The cursor is part of the video on Hyprland.** It moves with video
  latency, and on a static screen it can lag until something else on the
  display changes. Hyprland's cursor-capture interface cannot deliver the
  cursor image yet, so the separate cursor channel stays off there. Use
  `--cursor off` to leave it out.
* **CPU encoding.** Hardware encoding (VA-API, V4L2) is not used yet, so
  encoding runs on the CPU with x264. A 5K iMac streamed at 4096x2304 costs
  noticeably more CPU and shows about 55-70 ms end to end, against ~20 ms for
  an iPhone.
* **Sway, KDE Plasma and GNOME are untested on real desktops.** See
  [Supported setups](#supported-setups).
* **Android** is untested beyond a first session: touch, scroll, rotation,
  lock and quit are not checked yet.

## Reporting a problem

[Open an issue](https://github.com/peetzweg/opendisplay/issues/new/choose)
(or comment on [#299](https://github.com/peetzweg/opendisplay/issues/299))
with:

1. The output of `od-sender doctor`.
2. A debug log of the failing session:
   ```sh
   RUST_LOG=debug od-sender run --to <receiver> 2>&1 | tee od-sender.log
   ```
3. Your distro, desktop and its version (`hyprctl version`, `sway --version`,
   `plasmashell --version` or `gnome-shell --version`), CPU architecture, and
   the receiver device and app version.

A report that an "expected to work" or experimental setup works is just as
useful.

## Linux receiver (beta)

`od-receiver` turns a Linux machine's screen into an OpenDisplay display:
a Mac or a Linux desktop extends onto it like onto an iPad. It is a GTK 4
window that fills the screen once a sender connects, draws the sender's
cursor and sends pointer input back. It is tested windowed on Asahi Linux /
Hyprland (aarch64), at 24 ms end to end; other desktops and fullscreen use
are expected to work but untested. Decoding runs in software through
GStreamer (`gst-libav`); VA-API hardware decoding (Intel/AMD,
`gst-plugin-va`) is used when installed. Like the sender, the stream is not
encrypted.

**Arch / Omarchy:** build the package from the same checkout as the sender:

```sh
sudo pacman -S --needed base-devel git
git clone https://github.com/peetzweg/opendisplay
cd opendisplay/linux/packaging/arch/opendisplay-receiver
makepkg -si                                   # update: git pull && makepkg -si
systemctl --user enable --now od-receiver     # optional: start with your session
```

**Any distribution:** the Flatpak bundle attached to the
[latest release](https://github.com/peetzweg/opendisplay/releases/latest),
for your machine (`uname -m`). Its GNOME runtime comes from Flathub:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user od-receiver-x86_64.flatpak     # or od-receiver-aarch64.flatpak
flatpak run app.opendisplay.Receiver
```

Then start "OpenDisplay Receiver" (or `od-receiver`): it advertises itself on
the network and waits. The Mac sender lists it like any other receiver; on
Linux, run `od-sender run --to <its hostname>`. `--windowed` keeps
it in a window, `--output <name>` picks the monitor, `od-receiver --help`
lists the rest. Problems and reports go to
[#284](https://github.com/peetzweg/opendisplay/issues/284).

## Development

The Rust workspace in this directory also holds the protocol crates
(`opendisplay-proto`, `opendisplay-session`, see [PROTOCOL.md](../PROTOCOL.md))
and `od-fake-sender`, which replays a clip into a receiver. Test sender
changes that create or remove outputs on a nested Hyprland
(`testbench/nested.sh`), never on your own session; `testbench/` also holds
the headless Sway, KDE Plasma, GNOME and receiver smoke tests that CI runs.
