# od-receiver on SteamOS and the Steam Frame

Written 2026-10-20, before the device was on hand. **[verified]** marks what was
run (on an aarch64 Asahi box, headless Sway/KWin); **[from frametop.md]** is
from `research/linux/frametop.md`; everything else is a plan or an
expectation to check on the Frame.

## 1. What the Frame gives a receiver

- **SteamOS, aarch64, read-only root.** `pacman` installs are wiped by updates,
  so the receiver must install per user: a **Flatpak** (this doc's main path)
  or a binary in `$HOME` built in a distrobox. Whether SteamOS ships GTK 4 and
  GStreamer in its base image is unknown (no public 3.8 manifest found); the
  Flatpak does not depend on it.
- **Desktop mode** is KDE Plasma (6.x) on Wayland. In the headset, "Native
  Desktop" is **KWin nested in gamescope**, shown as a panel SteamVR places;
  gamescope's OpenVR path caps it at **1920×1080** **[from frametop.md]**.
- **Decoder:** Qualcomm iris, V4L2 *stateful*, `/dev/video-dec0`, H.264/HEVC up
  to 8K, outputs NV12 / UBWC NV12; **no VA-API** **[from frametop.md]**.
- **Environment traps** **[from frametop.md]**: apps started from the VR
  launcher inherit Steam's `LD_LIBRARY_PATH`, whose libavcodec has no H.264
  decoder (Flatpak's sandbox does not inherit `LD_LIBRARY_PATH`, which
  sidesteps this); avahi runs on the host while od-receiver's `mdns-sd` binds
  5353 itself (both use port reuse; verify they coexist).

## 2. What od-receiver does today (receiver-beta)

- GTK 4 window (`--sink gtk`, the default): fullscreens itself on the chosen
  monitor (`--output <connector>`, else the first), inhibits idle, draws the
  sender's cursor sprite, hides the local pointer, sends the local pointer
  and scroll back as `touch`/`scroll` (§6.1), says `closing` when closed.
  **[verified]** on headless Sway (CPU path) and headless KWin (GL path).
- Decode: `decodebin3` picks the highest-ranked H.264 decoder. A decoder that
  shows nothing within 15 frames (or errors) is skipped and the pipeline
  rebuilt with the next one; `stats.decoder` names the decoder and any skipped
  ones, `dec50`/`dec95` the push→sink time. **[verified]**: on Apple silicon
  the V4L2 *stateless* decoder is skipped into `fakesink` but works zero-copy
  into the GTK GL sink (56–58 fps, but 32 ms vs 2 ms for `avdec_h264`).
- `hello` reports `panel` from the GdkMonitor (physical pixels, fractional
  scale, logical size) and `videoCaps` (H.264 at the panel's rate).

## 3. Install on the Frame (Flatpak)

1. Desktop mode (or a terminal over SSH): download `od-receiver-aarch64.flatpak`
   from the OpenDisplay GitHub release (`releases/latest`; Linux ships in
   the app's `vX.Y.Z` releases).
2. `flatpak install --user od-receiver-aarch64.flatpak` — per user, survives
   SteamOS updates, no root. The GNOME runtime comes from Flathub (enabled on
   SteamOS); H.264 software decode needs the runtime's
   `org.freedesktop.Platform.codecs-extra` extension, which Flatpak installs
   with it.
3. Start **OpenDisplay Receiver** from the menu (or
   `flatpak run app.opendisplay.Receiver`). It advertises itself on the LAN;
   the sender finds it (`od-sender list` / the Mac app's list).

Development alternative: an Arch distrobox, `cargo build -p od-receiver` with
`gtk4 gst-plugins-{base,good,bad} gst-libav` inside, `/dev/video-dec0` passed
through, run from the container. Same binary, no Flatpak sandbox.

## 4. Autostart in desktop mode

- `cp /var/lib/flatpak/exports/share/applications/app.opendisplay.Receiver.desktop ~/.config/autostart/`
  (or the `~/.local/share/flatpak/exports/...` path for a `--user` install);
  Plasma starts it with the session. It waits for a sender and fills the
  screen when one connects.
- Or a user unit: `ExecStart=flatpak run app.opendisplay.Receiver`,
  `PartOf=graphical-session.target` (the AUR package's `od-receiver.service`
  with the Exec swapped).

## 5. Fullscreen inside the nested KWin, and how it looks in VR

- GTK asks KWin for fullscreen on its one output; KWin's nested output is the
  panel gamescope shows in VR, so the receiver fills that panel. `hello`
  reports that output's size (expect 1920×1080 at scale 1–2): the sender
  streams 1080p and sizes the extended desktop to it.
- In VR the user sees the panel where SteamVR puts the desktop; the cursor is
  the sender's (drawn by the receiver, not baked into the video); the
  laptop's own keyboard and touchpad drive the extended desktop, and the
  Frame's controllers/laser pointer act as a mouse over the panel, which
  od-receiver turns into `touch`/`scroll` for the sender.
- Each frame takes decode → GTK/GL → KWin composite → gamescope → SteamVR:
  two to three GPU passes and the 1080p cap. That is acceptable for proving
  the protocol, network and input; the product path is a native overlay
  (§7).

## 6. First experiment when the Frame arrives (about an hour, nothing in `/usr`)

From `frametop.md` §4, adapted to the GTK receiver and the Flatpak:

1. **Platform:** `cat /etc/os-release`, `kwin_wayland --version`,
   `v4l2-ctl --list-devices`, `ls /opt/steamvr/bin/linuxarm64`, and whether the
   host has `gst-inspect-1.0` / GTK 4 (`ls /usr/lib/libgtk-4*`).
2. **Install** the Flatpak (§3). Inside it: `flatpak run --command=gst-inspect-1.0
   app.opendisplay.Receiver v4l2h264dec avdec_h264 openh264dec`.
3. **Protocol only:** `flatpak run app.opendisplay.Receiver --sink none`, start
   `od-sender` on the Omarchy laptop. **Pass:** mDNS discovery, `hello`
   arrives, frames at full rate, Wi-Fi `rtt` acceptable.
4. **Present, windowed, in desktop mode on the Frame's own screen:**
   `flatpak run app.opendisplay.Receiver --windowed`. Note `stats.decoder`
   (did `v4l2h264dec` take it or was it skipped?), `dec50`, `renderFps`, CPU,
   the sender's cursor, laptop touchpad driving the desktop, the Frame's
   controllers as pointer.
5. **Fullscreen in VR (Native Desktop):** start it there; note the panel size
   `hello` reports, which output it fullscreened on, how it looks, latency
   feel; test that closing it ends the sender's session.
6. **Decoder choice:** repeat 4 with `--decoder avdec_h264` and
   `--decoder v4l2h264dec`; compare `dec50`/CPU.
7. **Optional:** Frametop's `ft-dectest` (S1 spike) on an H.264 clip, which
   needs a small H.264 patch to its HEVC-only AU splitter; proves the
   zero-copy overlay path for §7 on this SteamOS build.

## 7. The VR presenter (later, design (b1) in frametop.md)

A `--sink openvr` presenter behind the same `VideoOutput` trait: V4L2 iris
decode → GLES NV12→RGBA into a ring of dmabufs → `ImportDmabuf` overlay,
ported from Frametop's MIT `iris.h`, with laser events mapped to
`touch`/`scroll` and the cursor in a small child overlay. Its frame handoff
should follow Frametop's `buffers/frame/release/attention` socket protocol
so it can later run as an OpenDisplay backend inside Frametop (b2). The seam
in od-receiver: decode stays in GStreamer (or iris.h), the presenter
receives decoded dmabufs; `VideoOutput::cursor`/`cursor_image` already
carry the cursor separately.

## 8. Open questions for the device

- Does SteamOS (3.8 or the Frame's build) ship GTK 4 / GStreamer, and which
  KWin/Plasma version exactly?
- Does GStreamer's `v4l2h264dec` drive the iris decoder, which formats does it
  negotiate (NV12 linear vs UBWC `Q08C`), and does the GTK GL sink import them
  (else the fallback lands on `avdec_h264`)? Its decode latency?
- Does the Flatpak sandbox see `/dev/video-dec0` with `--device=all`, and the
  render node for GL?
- Do avahi and `mdns-sd` coexist on 5353; does the sender find the Frame?
- Which output does GTK fullscreen on in Native Desktop, and what size does
  `hello` report there?
- Do the Frame's controllers / laser pointer arrive as pointer events in the
  nested KWin (then `touch` works with no extra code)?
- Wi-Fi: rtt and stalls on the user's router vs. the Frame's hotspot.
