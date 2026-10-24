---
title: Install the Linux sender
nav: Install
description: Install od-sender, the OpenDisplay Linux sender (beta), from the prebuilt x86_64 or aarch64 tarball, as an Arch / Omarchy package, or from source.
order: 1
updated: 2026-10-22
---

There are three ways to install `od-sender`. The tarball and the Arch package
both come with a desktop entry and a `systemd --user` unit for
[starting on login](/docs/linux/usage/#start-on-login).

## Prebuilt tarball (any distribution)

Download the tarball for your machine (`uname -m` prints `x86_64` or
`aarch64`) from the
[latest release](https://github.com/peetzweg/opendisplay/releases/latest).

The tarballs link a minimal FFmpeg and x264 statically, so no FFmpeg install
is needed. They need:

- **glibc 2.38 or newer on x86_64** (Ubuntu 24.04, Debian 13, Fedora 39 and
  later), **glibc 2.39 or newer on aarch64** (Ubuntu 24.04, Debian 13,
  Fedora 40 and later);
- PipeWire's library, `libpipewire-0.3`, which every current desktop already
  has.

Unpack it and run the installer:

```sh
tar xf od-sender-$(uname -m)-unknown-linux-gnu.tar.gz && cd od-sender-$(uname -m)-unknown-linux-gnu
./install.sh                 # into ~/.local/bin, with the desktop entry and systemd --user unit
sudo ./install.sh --system   # or into /usr/local for every user
```

`install.sh` points the desktop entry and the unit at the installed binary,
which KDE Plasma 6.7 and older need (see
[KDE Plasma](/docs/linux/desktops/#kde-plasma)). If `~/.local/bin` did not
exist before, log out and in so it is on your `PATH`.

To **update**, install the next release's tarball the same way. To
**uninstall**, run `./install.sh --uninstall` (add `--system` for
`/usr/local`); see [Uninstall](/docs/linux/troubleshooting/#uninstall).

Licence texts for the bundled FFmpeg, x264, OpenH264 and Rust crates are in
`THIRD-PARTY-LICENSES.txt` inside the tarball.

## Arch / Omarchy: build the package

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
tests take about 2.5 minutes on an 8-core M1 Pro, longer on smaller machines.

To **update**, run `git pull && makepkg -si` in the same directory. An AUR
package follows once AUR registration reopens.

## From source

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

A binary run from `target/` has no desktop entry, which matters on KDE Plasma
6.7 and older; see [KDE Plasma](/docs/linux/desktops/#kde-plasma).

## Check the install

```sh
od-sender doctor
```

`doctor` prints how it detected your desktop, the Wayland protocols it found,
which encoders open and your config file, and changes nothing. Exit code 0
means `od-sender run` can work here. Next: [first run](/docs/linux/usage/).

## Get a receiver

The display side is any OpenDisplay receiver:

- **iPhone and iPad**: OpenDisplay from the
  [App Store](https://apps.apple.com/us/app/opendisplay/id6780264891).
- **Android**: the public beta on Google Play, Android 7.0+; join via the
  [home page](/).
- **Mac**: OpenDisplay Receiver from the
  [latest release](https://github.com/peetzweg/opendisplay/releases/latest)
  or `brew install --cask opendisplay-receiver`.
- **Linux**: the [Linux receiver](/docs/linux/receiver/) (beta).
