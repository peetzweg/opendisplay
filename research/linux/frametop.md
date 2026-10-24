# Frametop vs. "Steam Frame as OpenDisplay receiver"

Research 2026-10-20, read-only. Sources: [Frametop/frametop](https://github.com/Frametop/frametop) (moved from DeeJanuz/frametop on 2026-10-09; old URLs redirect), MIT, ~300 stars, very active (pushed today). Key docs: [README](https://github.com/Frametop/frametop/blob/main/README.md), [docs/reference.md](https://github.com/Frametop/frametop/blob/main/docs/reference.md), [docs/design.md](https://github.com/Frametop/frametop/blob/main/docs/design.md), and the most relevant one, [docs/remote-displays.md](https://github.com/Frametop/frametop/blob/main/docs/remote-displays.md). [nomadsgalaxy/frametop](https://github.com/nomadsgalaxy/frametop) is 2 commits ahead and 433 behind (a distrobox-init wait and an ft-pointer overlay-poll fix). Nothing of interest there. **[inferred]** marks my own conclusions. Everything else I read in the sources.

## 1. What Frametop is and how it works

- **What it is:** a multi-monitor KDE Plasma desktop that runs on the Frame itself, with no PC. Users can float single app windows into VR, save profiles, use a "3D mouse" (a Bluetooth mouse drives a dot in the room) and an experimental gaze pointer. It also has hand tracking, a VNC remote, and power and stand handling.
- **How it gets multiple screens:** it does not use virtual outputs, `zkde_screencast`, or PipeWire. **ft-screens** (`screens/compositor.c` + `screens/vr.cpp`) is its own small **wlroots 0.20 Wayland compositor**. A complete KWin/Plasma session runs *nested* inside it on KWin's nested Wayland backend. KWin opens one toplevel per output, and ft-screens resizes each toplevel with `xdg_toplevel.configure`. That gives every screen its own resolution, changeable live.
- **Approaches it dropped** (design.md):
  - gamescope `PerWindow` + `kwin --output-count N`: every screen got the same size, letterboxed. gamescope's OpenVR backend also **allocates a fixed 1920×1080×4 upload buffer and aborts on anything larger**.
  - KWin screencast virtual outputs: KWin 6.2.5 crashed (`textureForOutput` out_of_range) while nested in gamescope, and the headless backend has no virtual outputs.
  - WayVR: nothing showed on the Frame, and it needs `xdg-desktop-portal-kde`, which SteamOS doesn't ship.
- **How screens get into VR:** OpenVR overlays, not OpenXR. Each KWin buffer is a DMA-BUF imported with `vr::VRIPCResourceManager()->ImportDmabuf(VRApplication_Overlay, &DmabufAttributes_t, &handle)`. It is shown as a `TextureType_SharedTextureHandle` overlay texture with no copy and no size limit, and placed with `SetOverlayTransformAbsolute`. Curve, roll, pins and the controls it draws are separate small overlays. The interface is newer than the OpenVR header SteamVR ships, so the build pins the header from ValveSoftware/openvr **v2.15.6** and links SteamVR's own `/opt/steamvr/bin/linuxarm64/libopenvr_api.so` ([scripts/openvr.sh](https://github.com/Frametop/frametop/blob/main/scripts/openvr.sh)).
- **Per-screen frame rates by attention:** a screen you look at gets full rate, one in view gets 15 Hz, a hidden one 1 Hz. This works by throttling Wayland frame callbacks.
- **The 3D mouse:**
  - A SteamVR **driver** (`pointer/driver`) adds an invisible virtual controller that drives vrcompositor's `lasermouse` action set.
  - A helper turns mouse deltas into yaw/pitch around an anchor and hit-tests overlays with `ComputeOverlayIntersection`.
  - An input relay (`/dev/uinput`, started before SteamVR) keeps Bluetooth mice and keyboards alive across reconnects.
- **How it runs on the Frame:** inside SteamVR. It is launched from "Launch a program → Desktop", and its launcher entry replaces SteamOS's `deckard-nested-desktop`. The stock single-screen desktop stays available as "Native Desktop".
- **Install:** `curl … get.sh | bash`.
  - Everything goes in `$HOME`, plus a few `/etc` bits that need sudo. Nothing goes into `/usr`.
  - It builds inside a **distrobox Fedora `dev` container**. The binaries link the container's newer glibc, so they *run* in the container, except the SteamVR driver.
  - A prebuilt ~1.1 GB release zip also exists.
- **Stack:** C/C++ (compositor, VR, pointer, stream), Python/QML (Kirigami settings apps), shell. License **MIT**.
- **Tested on:** SteamOS **0.4.5** (build 20261007), SteamVR 2.18.2, KWin 6.2.5 per the docs. That doesn't match "SteamOS 3.8 / Plasma 6.4"; check `/etc/os-release` on the user's unit.

## 2. Constraints that matter for an OpenDisplay receiver

- **"No VNC server can capture KWin on SteamOS":** `krfb` needs `xdg-desktop-portal-kde` (not shipped) and `wayvnc` is wlroots-only. Frametop chains `krdpserver` → FreeRDP inside `Xvnc` instead. This is a *sender-side* problem: it would only matter if the Frame were the sender, not the receiver.
- **The stock VR desktop is KWin nested in gamescope**, so a window there goes through gamescope's OpenVR path, which is **capped at 1920×1080**. **[inferred]** od-receiver fullscreen in Native Desktop therefore shows at most a 1080p panel, scaled in by gamescope and placed by SteamVR's dashboard.
- **The hardware decoder** (remote-displays.md):
  - `/dev/video-dec0` (`qcom-iris-decoder`, Snapdragon 8 Gen 3 / Adreno 750) decodes H.264, HEVC and VP9 up to 8K.
  - It uses the V4L2 *stateful* API. Its outputs are `Q08C` (NV12 UBWC; no extra delay), linear NV12 (+2 frames of delay), and NV21. Its "RGBA" outputs are really 10-bit UBWC YUV.
  - Budget: 7.78 M macroblocks/s, which is one 8K60 stream. Steam Link VR shares the decoder.
  - **No VA-API** on the Frame.
  - FFmpeg `v4l2m2m` hasn't been tried for decode (its encoder segfaults). **[inferred]** Whether GStreamer's `v4l2h264dec` works on this downstream driver is unknown. `decodebin3` may fall back to `avdec_h264`, which is fine for 1–2 screens on the CPU.
- **SteamVR imports NV12 dmabufs but doesn't convert them** (red=Cr, green=Y, blue=Cb). You need one GLES pass:
  1. Sample the decoder buffer as `GL_TEXTURE_EXTERNAL_OES` with `EGL_YUV_COLOR_SPACE_HINT_EXT` / `EGL_SAMPLE_RANGE_HINT_EXT`.
  2. Draw into a ring of 3 RGBA buffers using the modifiers from `GetDmabufModifiers` (UBWC). SteamVR imports each of these once.

  Measured at 3440×1440@60: decode 2.1 ms, convert ~0.13 ms GPU, 2–3.5 % of one core, 0 missed compositor frames.
- **Environment pitfalls:**
  - Apps started from the VR launcher inherit Steam's `LD_LIBRARY_PATH`, whose libavcodec **has no H.264 decoder**. Frametop strips it.
  - OpenVR clients started inside a session with its own `XDG_CONFIG_HOME` fail with `PathRegistryNotFound`. Run them with `XDG_CONFIG_HOME=~/.config`.
  - Starting `VR_Init` as an overlay app *before* vrserver is up spawns a vrserver from the container that never finds the HMD and broke SteamVR launches. Connect as a background app first.
- **The 128-overlay system limit:** each Frametop panel uses 6–7 overlays.
- **A vrcompositor crash** happened when imports were freed while an overlay still showed them, and it took gamescope and Steam down with it. Tear down in this order: clear the textures, destroy the overlays, wait about 200 ms, then free the imports.
- **Updates:** SteamVR ships inside the OS image, and `IVRIPCResourceManagerClient` is semi-private, so updates can break things. Frametop has `scripts/doctor.sh` for this.
- **Wi-Fi:** routers lost bursts of 5–14 packets per frame. A Steam Link dongle on the Frame's hotspot lost none. OpenDisplay is TCP, so this shows up as stalls rather than corruption **[inferred]**.
- **mDNS:** `avahi` runs on the host. od-receiver uses `mdns-sd` on its own. **[inferred]** Both should coexist on 5353; verify.

## 3. Relation to OpenDisplay

**Frametop already built almost exactly design (b), for a different protocol.** "Remote Displays" (on `main`) streams other PCs' monitors into Frametop panels:

- **`stream/ft-stream.cpp`:** one process per display. It is a Moonlight client built on moonlight-common-c and libgamestream (GPLv3, pinned commit), talking to a host running Vibepollo or Sunshine.
- **`stream/spike/iris.h`:** a header-only V4L2 iris decoder (with an H.264 or HEVC `codec` field), an EGL/GLES NV12→RGBA converter, and an `ImportDmabuf` helper.
- **`screens/remote.c`:** spawns ft-stream over a `SOCK_SEQPACKET` pair. The protocol is text:
  - ft-stream sends `buffers W H FMT MOD OFF STRIDE` + 3 fds via SCM_RIGHTS, then `frame I` for each new picture, and `state`.
  - ft-screens sends `release I`, `attention focused|view|hidden`, `move X Y`, `button`, `scroll`, `key`, `blur`, `quit`.

  The remote screen then gets everything a native screen has for free: controls, curve, pins, profiles, the 3D mouse, gaze, and cross-panel drag routing.
- **Measured results:** about 5 ms from first packet to panel, 4–5 % of a core per 5120×1440@60 stream, and an IDR every 1 s for hidden panels.
- **What they rejected:** running Moonlight-qt in a window on a screen (design (a)-like). It costs two GPU passes per frame and can't drop to 1 Hz, but they kept it as a useful baseline.

**Overlap vs. complement.** Both use the same headset pipeline. The host side is where they differ, and that is OpenDisplay's niche:

| | Frametop Remote Displays | OpenDisplay |
|---|---|---|
| Host software | Windows/Linux need Vibepollo (Frametop's patched fork), macOS needs Sunshine | The user's own sender |
| Virtual displays | Vibepollo's Linux virtual displays are **x86_64 Arch/CachyOS + KDE + its own DKMS module only**. No Hyprland, no aarch64/Asahi. | Hyprland `output create headless` exists and the sender builds it |
| macOS | One display only | OpenDisplay already has a Mac sender |
| Cursor | Baked into the video, so it lags by a round trip | Separate cursor channel (§6.2/6.3) |
| Input needs | Needs VR keyboard/mouse | The laptop's own keyboard/trackpad drive the extended desktop |

So OpenDisplay's "Hyprland laptop → extended virtual screen" use case is something Frametop's host side doesn't cover. Frametop's headset side is the hard part, and it's MIT, which is compatible with OpenDisplay's GPL-3.0.

**Design (a): od-receiver fullscreen in the Frame's desktop.**
- **Effort:** about 1–2 days.
  - Build aarch64 od-receiver in an Arch distrobox, where gst plugins are available. SteamOS root is read-only.
  - Strip Steam's environment.
  - Run `--sink gl` fullscreen.
- **Risks:**
  - The stock Native Desktop caps at 1080p and SteamVR places the panel.
  - Decode may be software only.
  - Every frame takes two GPU passes plus KWin's composite.
  - Latency is unmeasured.
- **Inside Frametop's desktop:** it runs on a Frametop screen at any resolution, but with decoder → GL sink → KWin → ft-screens.
- **Verdict:** good for proving protocol, mDNS and network, poor as the product.

**Design (b): native SteamVR overlay receiver.** Two flavours:

- **(b1) Standalone "od-vr" overlay app:**
  - opendisplay-proto/session (Rust) → `iris.h`-style V4L2 decode → GLES convert → `ImportDmabuf` ring → one overlay you can place and curve.
  - Laser events (`VREvent_MouseMove/ButtonDown`) map to `touch`/`scroll`.
  - The cursor channel draws into a small child overlay.
  - Effort: about 2–4 weeks **[inferred]**, mostly placement UX, an FFI shim for C++ OpenVR, and SteamOS-update fragility.
- **(b2) Frametop remote-screen backend:** an `od-stream` helper that speaks Frametop's ft-stream socket protocol on one side and OpenDisplay on the other. Frametop's `remote.c` would launch it instead of ft-stream for an "OpenDisplay host".
  - Effort: about 1–2 weeks **[inferred]**, plus an upstream PR or design discussion with Frametop.
  - Placement, curve, profiles, 3D mouse, gaze and multiple screens all come for free.
  - Risk: you depend on a fast-moving third-party project, and only Frametop users get it.

**What can be reused from Frametop (MIT, keep the copyright notice):**
- `iris.h`: Decoder (incl. the `msm_media_info.h` UBWC plane layout and `G_SELECTION` crop) and Converter.
- The `GetDmabufModifiers`/`ImportDmabuf` usage and the pinned OpenVR header approach.
- The overlay teardown order.
- The attention policy (decode everything, show about 10 fps when hidden).
- The socket protocol design.

`ft-stream.cpp`'s Moonlight and libgamestream parts are irrelevant (and GPL), and `stream/` has no separate licence file yet.

## 4. Recommendation and first experiment

**"Our own way":**
1. Keep the OpenDisplay protocol and sender as the product's value.
2. Use design (a) only as a smoke test.
3. Build the VR receiver as a **thin headset backend behind od-receiver's `VideoOutput` trait**: a `--sink openvr` that does V4L2 iris decode → GLES → `ImportDmabuf` overlay, ported from iris.h.
4. Shape its frame handoff like Frametop's `buffers/frame/release/attention` protocol, so the same code can later run as (b2) inside Frametop.
5. Propose (b2) upstream to Frametop **after** (b1) works. Their "Alternatives considered" says they won't own a host streamer. OpenDisplay *is* one for Hyprland and macOS, so the pitch fits.

**First experiment when the Frame arrives (about an hour, nothing installed into `/usr`):**
1. Check the platform: `cat /etc/os-release`, the KWin version, `v4l2-ctl --list-devices`, `ls /opt/steamvr/bin/linuxarm64`, and whether the host has `gst-inspect-1.0`.
2. In an Arch distrobox on the Frame: build `od-receiver` (aarch64, natively), check `gst-inspect-1.0 v4l2h264dec avdec_h264`, and give the container `/dev/video-dec0` access.
3. Run `od-receiver --listen 0.0.0.0:9000 --sink none` and start `od-sender` on the Omarchy laptop. **Pass:** mDNS discovery works, `hello` arrives, frames come in at full rate, and the rtt over Wi-Fi is acceptable.
4. Run it again with `--sink gl` fullscreen in Native Desktop, with Steam's `LD_LIBRARY_PATH` unset. Note which decoder `decodebin3` picks, plus CPU, the panel resolution you actually see (expect ≤1080p), and how the laptop's cursor looks.
5. Optional: with Frametop installed, run its `ft-dectest` (S1 spike) on an H.264 clip (`linux/testdata/clip-320x180-30.h264` plus a 1440p clip). It is HEVC-only today: its AU splitter parses HEVC NALs, so it needs a small H.264 patch. This proves the zero-copy overlay path for (b) on this exact SteamOS build.
