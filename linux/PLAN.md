# OpenDisplay on Linux: sender + receiver plan

Status: **planning**, 2026-09-21. Supersedes the scope split in #284 (receiver
only) and #84 (Linux sender, no plan). Everything below was researched and, where
marked *verified*, tested on the machines listed in §1.

Goal: a native Rust **receiver** and **sender** for Linux, running on `x86_64`
and `aarch64`, built as a clean-room implementation against `PROTOCOL.md`
(`pv` 3). Omarchy (Arch + Hyprland) is the first target; a NixOS headless kiosk
receiver (the 2017 5K iMac from #284/#272) is the second and must fall out of
the same code, not a fork.

---

## 1. Machines and what each can prove

| Machine | What it is | Can prove | Cannot prove |
|---|---|---|---|
| Dev VM (this repo's Omarchy box) | **aarch64 QEMU VM** (`linux,dummy-virt`, 8 vCPU, virtio-gpu), Omarchy, Hyprland 0.56.1, PipeWire 1.6.8, GStreamer 1.28.7, ffmpeg 9.0.1. Network is QEMU user-mode NAT (`10.0.2.15/24`). | Everything protocol-level; software encode/decode; Wayland present via `waylandsink`; Hyprland headless outputs, capture and input protocols; arm64 build. | Any hardware codec (no VA-API, no Vulkan video); mDNS across the NAT; running x86 binaries. |
| Intel iMac 2017, full Omarchy (coming) | x86_64, Radeon Pro 570/575/580 (Polaris, UVD 6.3 / VCE 3.4, 4K-class), 5K panel | VA-API decode **and** encode via `radeonsi`; real end-to-end latency on glass; Spike 0; the exact hardware the NixOS kiosk will later run on. | ARM anything. |
| Mac (M1 host of the VM) | Runs the shipping macOS sender | Interop of the Linux receiver with the real sender. | — |
| iPhone/iPad | Runs the shipping iOS receiver | Interop of the Linux sender with the real receiver. | — |

**Dev-VM networking note.** `10.0.2.x` is QEMU SLIRP: the host cannot reach the
guest and multicast does not cross it. To run the Mac sender against a receiver
in this VM either (a) add a UTM/QEMU port forward host `9000` → guest `9000` and
launch the Mac sender with its manual endpoint escape hatch
(`Mac/OpenSidecarMacApp.swift:187`: `-host 127.0.0.1 -port 9000`, the `-host`
default key being set is what selects plain TCP), or (b) switch the VM to
shared/bridged networking so Bonjour discovery works normally. Option (a) is
enough for all of Milestone 2.

---

## 2. Verified findings (2026-09-21, dev VM)

### 2.1 Hyprland can create and size a virtual display

```sh
hyprctl output create headless od0
hyprctl eval 'hl.monitor({output="od0", mode="2732x2048@120", position="auto", scale=2})'
grim -o od0 -t ppm - | head -2        # -> P6 / 2732 2048
hyprctl output remove od0
```

Arbitrary size, refresh and scale, created and torn down at runtime, and
capturable via `wlr-screencopy` immediately. This is the `CGVirtualDisplay`
equivalent #284 said Linux lacks. Caveats:

* Hyprland ≥ 0.55 is **Lua-configured**; `hyprctl keyword` is rejected
  ("keyword can't work with non-legacy parsers"). Use the IPC socket
  (`$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`) with
  `eval hl.monitor({...})`. `eval` returns `ok` even for inert Lua, so verify via
  `monitors -j` afterwards.
* `zwlr_output_manager_v1` is also exposed; its `set_custom_mode` would be the
  compositor-agnostic way to size the output (works on sway too). Unverified
  on headless outputs, check in Spike 0.

### 2.2 Wayland globals Hyprland 0.56.1 exposes (from the binary)

Capture: `zwlr_screencopy_manager_v1`, `ext_image_copy_capture_manager_v1`,
`ext_output_image_capture_source_manager_v1`,
`ext_foreign_toplevel_image_capture_source_manager_v1`,
`hyprland_toplevel_export_manager_v1`, `zwp_linux_dmabuf_v1`.
Timing: `wp_presentation`, `wp_fifo_manager_v1`, `wp_commit_timing_manager_v1`.
Input: `zwlr_virtual_pointer_manager_v1`, `zwp_virtual_keyboard_manager_v1`.
Output: `zwlr_output_manager_v1`, `zwlr_output_power_manager_v1`.
Surfaces: `xdg_wm_base`, `zwlr_layer_shell_v1`, `wp_viewporter`,
`wp_fractional_scale_manager_v1`, `wp_tearing_control_manager_v1`.

Hyprland's `ext-image-copy-capture` implementation (`src/protocols/ImageCopyCapture.cpp`)
supports shm **and dmabuf**, sends `presentation_time`, always reports
full-frame damage, and implements **pointer cursor sessions**
(`create_pointer_cursor_session`: enter/leave/position/hotspot + cursor image
delivered separately from the screen, gated by Hyprland's permission rules).
That is exactly the data `cursor` / `cursorImg` (§6.2) and the UDP side
channel (§6.3) need.

### 2.3 The portal is not the primary path on Hyprland

`xdg-desktop-portal-hyprland` reports `AvailableSourceTypes = MONITOR|WINDOW|VIRTUAL`
but its `Screencopy.cpp` has no code path that creates a virtual output: the
`VIRTUAL` bit is a lie. Cursor modes are `HIDDEN|EMBEDDED` only (no `METADATA`).
It does support restore tokens (`persist_mode = 2`), and hands dmabuf to
PipeWire. Verdict: use the Wayland protocols directly on Hyprland/wlroots; keep
the portal (`ashpd`) as a later backend for GNOME/KDE, where `VIRTUAL` is real
on mutter.

### 2.4 Software codec headroom on 8 ARM vCPUs

300 synthetic frames (`testsrc2`), ffmpeg 9, `-benchmark rtime`:

| Path | 1920×1080 | 2560×1600 | 3840×2160 |
|---|---|---|---|
| x264 `ultrafast` + `zerolatency`, 8 threads, sliced | 553 fps | 305 fps | 159 fps |
| x264 `veryfast` + `zerolatency` | 244 fps | 139 fps | — |
| ffmpeg `h264` decode, 8 threads | 2069 fps | 1667 fps | 1027 fps |
| ffmpeg `h264` decode, **1 thread** | 633 fps | 433 fps | 264 fps |

Real desktop content costs roughly 2× the synthetic source. Conclusions:
software decode is never the receiver bottleneck (presentation pacing is);
software encode is a viable fallback tier on ARM up to ~1440p60 and a real
option on Apple Silicon under Asahi, where the hardware **decoder** (AVD) is
landing but no encoder is exposed.

### 2.5 Toolchain and cross-compilation

* Pure Rust `aarch64` → `x86_64-unknown-linux-musl` works with no extra
  toolchain (`linker = "rust-lld"`, `+crt-static`); `x86_64-unknown-linux-gnu`
  does not (needs a cross gcc). Verified in the first session.
* The moment GStreamer/libva/ffmpeg link in, cross-compilation is not worth it.
  **Build natively per arch.** GitHub-hosted `ubuntu-24.04-arm` runners are GA
  and free for public repos; CI is a two-entry matrix.
* This VM cannot execute x86 binaries (no `qemu-user`, no binfmt handlers).

### 2.6 Rust ecosystem (crates.io, 2026-09-21)

`wayland-client` 0.31.15, `smithay-client-toolkit` 0.21.1,
`wayland-protocols` 0.32.13, `wayland-protocols-wlr` 0.3.12, `drm` 0.15.0,
`gstreamer` 0.25.3 (+ `-app`, `-video`, `-allocators`), `ffmpeg-next` 9.0.0
(matches Arch's ffmpeg 9), `openh264` 0.9.8, `x264` 0.5.0 (stale, 2022),
`mdns-sd` 0.21.4 (pure Rust responder+browser, updated 2026-09-21), `zbus` 5.19,
`ashpd` 0.13.13, `pipewire` 0.10.1, `wgpu` 30, `tokio` 1.53.

### 2.7 Omarchy packaging facts

Installed on the dev VM: `gstreamer`, `gst-plugins-base-libs`,
`gst-plugins-bad-libs` (gives `appsrc`, `h264parse`, `waylandsink`, `kmssink`,
`vulkansink`). **Not** installed: `gst-plugins-good`, `gst-plugins-bad`,
`gst-libav` (`avdec_h264`), `gst-plugin-va` (`vah264dec`/`vah264enc`),
`gst-plugin-pipewire`, `libva-utils`. Avahi is installed but `avahi-daemon` is
inactive. All are in `extra`.

---

## 3. Technical decisions

### 3.1 Language: Rust

As #284 argues. The wire is trivial in any language; the cost is the media
stack, which forces native linking regardless.

### 3.2 Repository: this repo, `linux/` Cargo workspace

The spec, the conformance tests and the existing `tools/` live here, and the
whole point is building against `PROTOCOL.md`. A separate repo would drift.

```
linux/
  Cargo.toml                  workspace
  crates/
    opendisplay-proto/        §3 framing, §4 demux (one isolated fn), §6 message types,
                              hello/welcome negotiation. Sans-I/O, no platform deps.
    opendisplay-session/      sender AND receiver state machines: §8 liveness, clock
                              offset, kf recovery, adopt-and-drop, reconnect policy,
                              cursor sequence tracking. Sans-I/O, driven by events.
    od-receiver/              Wayland fullscreen surface, mDNS advertise, decode+present.
    od-sender/                compositor backend, capture, encode, cursor, input injection,
                              mDNS browse.
    od-fake-sender/           replays an Annex B .h264 over the wire; flags to force
                              SPS/PPS change, drop frames (exercise kf), pause (exercise
                              reconnect). Mirror of tools/fake-receiver.swift.
  flake.nix                   packages.{x86_64,aarch64}-linux, devShell pinning
                              GStreamer/libva/Mesa, nixosModules.receiver-kiosk
  packaging/arch/PKGBUILD     Omarchy/AUR
```

Most work lands in the two portable crates. Decode/present and capture/encode
are never portable; do not abstract them beyond a backend trait.

### 3.3 Sequencing: receiver first

The shipping Mac sender exists, so the Linux receiver gets a production peer on
day one. The sender comes second and is validated against the shipping iOS
receiver. Each half is tested against something real, never only against our
own other half.

### 3.4 Receiver media path: GStreamer

```
appsrc (one access unit per buffer) ! h264parse ! decodebin3 ! waylandsink
```

Reasons: `waylandsink` already does zero-copy dmabuf import into a fullscreen
surface (the one genuinely hard receiver problem); decoder selection by element
rank at runtime is what lets one binary use `vah264dec` (x86 VA-API),
`v4l2slh264dec`/`v4l2h264dec` (ARM SoCs), and `avdec_h264` (software, incl.
Asahi today) with no per-machine code. Known cost, per #284 and
`iOS/MetalVideoRenderer.swift`: sink/pipeline buffering. Start with
`sync=false`, `queue max-size-buffers=1 leaky=downstream`, `qos=true`; measure
with `wp_presentation` feedback; fall back to `ffmpeg-next` + `wgpu` only if
pacing proves opaque.

Runtime plugin requirements are probed at startup and reported clearly
("install gst-libav or gst-plugin-va") rather than failing inside GStreamer.

### 3.5 Sender media path: capture is ours, encoder behind a trait, decide in Spike 0

No framework has a Wayland screencopy source, so capture is `wayland-client` +
`ext-image-copy-capture-v1` (fallback `wlr-screencopy-v1`) producing dmabufs,
with a cursor session alongside. Two proven ways to encode a dmabuf:

1. `ffmpeg-next`, VA-API via DRM hwframes: exactly what
   [wl-screenrec](https://github.com/russelltg/wl-screenrec) (Rust, runs on
   Hyprland) does. Readable, working reference code.
2. GStreamer `appsrc` with `DMA_DRM` caps → `vapostproc ! vah264enc`
   (`gstreamer-allocators` for the dmabuf memory).

Both get tried on the iMac in Spike 0; the one with less friction wins. Either
way the fallback tier is `x264` `ultrafast`/`zerolatency` (§2.4). Encoder
constraints (High@L5.2 macroblock rate, #271) are enforced on our side before
choosing the operating point announced in `streamConfig`.

### 3.6 Compositor backend trait (sender)

```rust
trait CompositorBackend {
    fn create_virtual_output(&mut self, size: (u32,u32), hz: u32, scale: f64) -> Result<OutputHandle>;
    fn remove_virtual_output(&mut self, h: OutputHandle) -> Result<()>;
    fn output_name(&self, h: &OutputHandle) -> &str;   // for wl_output matching by name
}
```

| Backend | Create output | Capture | Cursor | Input | When |
|---|---|---|---|---|---|
| `Hyprland` | IPC: `output create headless`, `eval hl.monitor(...)`, `output remove` | ext-image-copy-capture / wlr-screencopy | ext cursor session; fallback IPC `cursorpos` (~2.6 ms per spawned `hyprctl`, sub-ms over the raw socket) | wlr-virtual-pointer (`create_virtual_pointer_with_output`, `motion_absolute`), virtual-keyboard | **M3** |
| `Sway`/wlroots | `swaymsg create_output` + `zwlr_output_manager_v1.set_custom_mode` | same | same protocols where implemented | same | M6 |
| `Portal` (GNOME/KDE) | `ashpd` ScreenCast with `VIRTUAL` source (real on mutter) | PipeWire | `METADATA` cursor mode | RemoteDesktop portal | M6 |

Hyprland's IPC and config surface churn (0.55 broke `hyprctl keyword` for every
tool, see Omarchy #6968): keep this backend thin, version-check on start, and
verify every mutation by reading `monitors -j` back.

Virtual output lifecycle: create on `hello` named `opendisplay-<short id>`,
mode `pixelsWide×pixelsHigh@displayMaxFrameRate`, `scale = hello.scale`,
position configurable (left/right of the primary, like the Mac sender's
`DisplayArrangement`); remove after the reconnect grace expires or on `closing`.

### 3.7 Discovery: `mdns-sd`

Pure-Rust mDNS responder (receiver: `_opensidecar._tcp`, TXT `id`, `pv=3`) and
browser (sender). No Avahi daemon dependency, which matters because Omarchy
ships Avahi inactive and the kiosk should not need it. Behind a `Discovery`
trait so an Avahi-via-`zbus` implementation can be added if coexistence on
port 5353 ever misbehaves.

### 3.8 `hello` on a Linux receiver

* `pixelsWide`/`pixelsHigh`, `displayMaxFrameRate`: from the chosen `wl_output`'s
  current mode.
* `scale`: the output's scale (Hyprland reports fractional; send the integer the
  user wants the sender to size points by, default `round(scale)`; config
  override). Resolves the first open question in #284: infer, allow override.
* `device`: `"Linux"`. Free-form per spec; nothing in the Mac sender branches on
  it except UI text.
* `id`: UUID persisted in `$XDG_STATE_HOME/opendisplay/id`, also in TXT.
* `maxEncodeWide`/`maxEncodeHigh` and `videoCaps`: from a **startup decode
  benchmark** (decode a bundled clip at candidate sizes, keep the largest that
  sustains the panel rate), per §6.5's "derive from measured playback". Cache
  the result keyed by GPU/driver/kernel.
* `cursorPort`: bound UDP `port+1`, offered from M4.

### 3.9 Packaging and deployment

* **Omarchy/Arch**: `linux/packaging/arch/PKGBUILD` builds from a checkout
  (`makepkg -si`; pacman resolves build and run-time deps). Dependency split:
  build-time only `pkgconf cargo gcc`; run-time `gst-plugins-good`,
  `gst-plugins-bad`, `gst-libav` (plugins are dlopen'ed by name, so they must
  stay real deps), optdepends `gst-plugin-va` (x86 hardware), `libva-utils`,
  `gst-plugin-pipewire` (portal backend, future). The sender needs nothing
  beyond libwayland today (OpenH264 is compiled in). At first release: AUR
  `opendisplay-bin` pulling the CI-built `x86_64`/`aarch64` binaries, so
  `yay -S opendisplay-bin` is the Omarchy one-liner; ships a `.desktop` entry
  and a `systemd --user` unit for autostarting the receiver.
* **NixOS**: `flake.nix` with `packages` for both arches, a `devShell`, and
  `nixosModules.receiver-kiosk` = `services.cage.program = od-receiver` +
  autologin-free boot + power-button shutdown. Same binary as Omarchy.
* **CI**: GitHub Actions matrix `ubuntu-24.04` × `ubuntu-24.04-arm`, native
  builds, `cargo test` for the two portable crates, conformance run with
  `od-fake-sender` against `od-receiver --null-sink`; plus `nix build` for
  both systems.

---

## 4. Milestones

0. **Spike 0 (iMac, when available; ~2 days).**
   *Partial status 2026-09-21 (dev VM, software path):* `od-sender` has the
   Hyprland IPC backend (`monitors`, create/configure/remove headless outputs —
   2732×2048@120 scale 2 came up in 58 ms) and an `ext-image-copy-capture-v1`
   shm capture loop (`od-sender capture-test`). Findings: Hyprland offers
   `Argb8888`/`Xrgb8888` shm; capture is **damage-driven** — a static output
   yields no frames, so the sender must keep the last encoded IDR to replay on
   connect/`kf` (§5.3) and must not treat silence as a stall; first frame after
   26–61 ms; frame interval p50 ≈ 17 ms while an output is animating. Remaining
   for the real Spike 0: dmabuf buffers, VA-API encode, cursor session, and
   `zwlr_output_manager_v1.set_custom_mode` — all need the iMac.
   **Spike 0 proper:** Rust program that: creates a
   headless output over Hyprland IPC, captures dmabufs via
   ext-image-copy-capture at the output rate with a cursor session, feeds them
   to (a) `h264_vaapi` via `ffmpeg-next` and (b) `vah264enc` via GStreamer,
   logs capture→bitstream latency. Output: the §3.5 decision and a measured
   VA-API ceiling on Polaris. Also verify `zwlr_output_manager_v1.set_custom_mode`
   on a headless output (§2.1).
1. **`opendisplay-proto` + `opendisplay-session` + `od-fake-sender`.** Property
   tests for framing across arbitrary read boundaries, §4 demux incl. the
   video-frame-starting-with-`{` case, telemetry-prefix stripping, unknown
   type/field tolerance, clock-offset math, adopt-and-drop. Green on both CI
   arches. Can be done entirely on the dev VM.
   *Status 2026-09-21: done on branch `linux-plan` — 47 tests incl. a
   sender/receiver loopback suite and a TCP end-to-end run of the fake sender;
   `.github/workflows/linux.yml` runs it on both arches. Adopt-and-drop is
   host-level and lands with the receiver binary in M2.*
2. **Receiver v1 (dev VM, then Omarchy laptops).** Fullscreen `waylandsink`,
   software decode via `gst-libav`, hardware where `gst-plugin-va` is present,
   `hello`/`ping`/`kf`/`welcome`, latest-wins present, `stats`. Validated
   against the **real Mac sender** through a UTM port forward (§1). First real
   picture.
   *Status 2026-09-21: `od-receiver` implemented on `linux-plan` — TCP with
   adopt-and-drop, optional UDP cursor port, `mdns-sd` advertisement, panel
   facts from `wl_output` v4, `stats` every 5 s, GStreamer
   `appsrc ! h264parse ! decodebin3 ! queue(leaky,1) ! waylandsink` behind a
   `VideoOutput` trait with a `--sink none` protocol-only mode. Verified live on
   the dev VM against `od-fake-sender` (sink none). **Not yet verified:** decode
   and present (needs `gst-libav`/`pkgconf` on the VM) and the real Mac sender.*
3. **Sender v1 (Hyprland).** Headless output sized from `hello`, capture,
   encode (per Spike 0), IDR on connect/`kf`, `welcome`, `pong`, cursor over
   TCP via the ext cursor session, `touch`→pointer and `scroll` injection.
   Validated against the **real iOS receiver**.
   *Status 2026-09-21: software path running on the dev VM — `od-sender run
   [--connect addr | --name X]` dials or discovers a receiver, creates
   `od-<id>` from `hello` (mode = panel pixels @ displayMaxFrameRate, scale =
   hello.scale, position configurable), captures it via ext-image-copy-capture
   (cursor baked in for now), encodes with **OpenH264** (bundled, no system
   deps), sends `streamConfig`, IDR on connect/`kf` with static-screen replay,
   removes the output on disconnect, redials. Verified against `od-receiver
   --sink none`. `touch`→`zwlr_virtual_pointer_v1` absolute motion + left button and
   `scroll`→axis events bound to the virtual output are in and verified via
   `od-sender input-test` (IPC `cursorpos` matches to the pixel). **Not done:**
   cursor session/`cursor` messages, hardware encode, iOS receiver test (needs
   network).*
   *Software encoder reality (release build, 8 ARM vCPUs, incl. BGRA→I420):
   OpenH264 1280×800 ≈ 10 ms/frame, 1080p ≈ 21 ms, 2560×1600 ≈ 43 ms, 2732×2048
   ≈ 62 ms. That is 3–8× slower than x264 `ultrafast` (§2.4), so OpenH264 is
   the zero-dependency floor only; the real software tier should be x264
   (`x264enc` via GStreamer or libx264 directly) and the real path VA-API.*
4. **Latency and polish.** UDP cursor side channel + `cursorAck`, `stats`
   with `e2e50/95` from the telemetry prefix + clock offset, `wp_presentation`
   based present timing, `streamConfig`/`videoCaps` intersection, adaptive
   operating point.
5. **NixOS kiosk.** `flake.nix`, `receiver-kiosk` module, deploy to the iMac
   under `cage`, VA-API Polaris decode, 4K60 Fill / Sharp modes from #272,
   clean shutdown on power button.
6. **Breadth.** Sway/wlroots backend, portal backend for GNOME/KDE, Asahi
   hardware decode once the AVD driver reaches distro kernels, HEVC when the
   spec adds it (#272).

---

## 5. Open questions (need a decision)

1. Cursor in the v1 sender: embedded in the video (zero work, moves at video
   latency) or the ext cursor session from the start? Recommendation: session
   in M3, UDP channel in M4.
2. Same repo `linux/` (recommended) vs. separate repo — #284 left it open.
3. Does the receiver-initiated session proposal (#243) change the kiosk's
   connection model enough to wait? Recommendation: no; M5 ships with the
   sender dialing, #243 layers on top additively.
4. QUIC spike (#273) would change §3 framing. Recommendation: target `pv` 3
   TCP as specified; the framing lives in one crate and is cheap to swap.
5. `hello.scale` policy (§3.8) — infer + override acceptable?

---

## 6. Filed on GitHub (2026-09-22)

Draft PR #298 (`linux-plan`); status comment on #284; sender issue **#299**
(supersedes #84); cross-references on #84 and #15. The drafts below are kept
for the record. Still to do: the upstream GStreamer report (§6.4) and the doc
updates (§6.5). Next-machine checklist: `linux/HANDOFF.md`.

### Drafts as posted

### 6.1 Comment on #284

> Research update, 2026-09-21. Plan and verified findings now live in
> `linux/PLAN.md` on branch `linux-plan`. Corrections to this issue's premises:
>
> * **Linux does have a `CGVirtualDisplay` equivalent on Hyprland**: `hyprctl
>   output create headless` + `hl.monitor({mode=..., scale=...})` creates an
>   arbitrary-size virtual output at runtime, capturable via
>   wlr-screencopy/ext-image-copy-capture. Verified on Hyprland 0.56.1. The
>   Linux *sender* is therefore not "fundamentally harder" on wlroots-family
>   compositors and is now in scope as a sibling effort (see the new sender
>   issue).
> * **ARM is involved**: the effort targets `x86_64` and `aarch64`. Software
>   x264/ffmpeg numbers on 8 ARM vCPUs (1080p60 encode at ~550 fps synthetic,
>   decode single-threaded at ~630 fps) make a software tier viable.
> * **Build natively per arch** (GitHub `ubuntu-24.04-arm` runners are GA) instead
>   of cross-compiling; the Nix `pkgsCross` path is unnecessary.
> * The portal is not the capture path on Hyprland: xdph advertises the
>   `VIRTUAL` source type but does not implement it, and lacks `METADATA` cursor
>   mode.
> * Omarchy (Arch + Hyprland) is the first target; the NixOS `cage` kiosk on the
>   2017 iMac is Milestone 5 and shares the binary.
> * Sequencing: receiver first (validated against the shipping Mac sender), then
>   sender (validated against the shipping iOS receiver).
>
> Open questions from the issue body, proposed answers: `scale` → infer from the
> output, allow override; `device` → `"Linux"`; #243 → don't wait, additive;
> same repo, `linux/` workspace; target `pv` 3 TCP, not QUIC.

### 6.2 New issue: "Linux sender (Hyprland first): virtual output, capture, encode, input"

> Sibling of #284; supersedes #84.
>
> **Goal.** A Rust sender for Linux so a Linux desktop can extend onto an
> iPhone/iPad (or the Linux receiver). Hyprland/Omarchy first, wlroots/sway and
> portal-based compositors later.
>
> **Why it is feasible now.** Hyprland exposes everything a sender needs without
> private APIs: runtime headless outputs (`hyprctl output create headless`,
> `hl.monitor({...})`), `ext-image-copy-capture-v1` with dmabuf and pointer
> cursor sessions, `wp_presentation`, `zwlr_virtual_pointer_v1` and
> `zwp_virtual_keyboard_v1`. wl-screenrec (Rust) and Sunshine (C++) already do
> dmabuf → VA-API zero-copy encode on Hyprland.
>
> **Scope v1.** Discover/dial receiver, `welcome`/`pong`/`ping`, create virtual
> output from `hello`, capture, H.264 encode per §5 (4-byte start codes, SPS/PPS
> on IDR, IDR on connect and `kf`), cursor via `cursor`/`cursorImg`, `touch` →
> absolute pointer, `scroll` → axis. Out of scope v1: pencil, audio, USB, UDP
> cursor (M4), non-Hyprland backends (M6).
>
> **Decisions pending Spike 0** on the Intel iMac: ffmpeg-next vs GStreamer for
> the dmabuf → VA-API encode path; `zwlr_output_manager_v1.set_custom_mode` on
> headless outputs.
>
> See `linux/PLAN.md` §3.5–3.6 and milestones 0, 3, 4, 6.

### 6.3 Close / relabel

* #84 "Linux -> iOS": close as superseded by the new sender issue.
* #15 "Exploratory: additional client platforms": comment that the
  precondition (reference spec + versioning) shipped and the Linux
  implementation is tracked in #284 + the sender issue.

### 6.4 Upstream bug: GStreamer `waylandsink` crashes on output hotplug

File at <https://gitlab.freedesktop.org/gstreamer/gstreamer/-/issues> (component
gst-plugins-bad / wayland). Reproduced on Hyprland 0.56.1, GStreamer 1.28.7:

```sh
gst-launch-1.0 videotestsrc ! waylandsink &
hyprctl output create headless x      # -> gst-launch: Caught SIGSEGV
```

Backtrace (thread `GstWlDisplay`): `wl_display_dispatch_queue_pending` →
`libgstwayland output_done` → `g_mutex_lock` (SEGV_MAPERR). Cause, in
`gst-libs/gst/wayland/gstwldisplay.c`:

```c
static void
output_done (void *data, struct wl_output *wl_output)
{
  GstWlOutput *output = GST_WL_OUTPUT (data);
  GstWlDisplay *self = g_object_steal_data (G_OBJECT (output), "display");
  GstWlDisplayPrivate *priv = gst_wl_display_get_instance_private (self);
  ...
  g_mutex_lock (&priv->outputs_mutex);
```

`wl_output.done` is emitted after *every* batch of output property changes,
not once per output. Adding an output makes the compositor re-send geometry
(+ `done`) for the existing ones; the second `done` finds the stolen data gone,
`self` is NULL, `priv` is garbage, `g_mutex_lock` faults. Proposed fix:

```diff
-  GstWlDisplay *self = g_object_steal_data (G_OBJECT (output), "display");
+  GstWlDisplay *self = g_object_get_data (G_OBJECT (output), "display");
```

(and drop the `g_object_set_data` ref only when the output is removed in
`registry_handle_global_remove`). Impact for us: the receiver died whenever
the sender created its virtual display on the same compositor, and it would
die on any laptop that docks a monitor mid-session. Until fixed, `od-receiver`
defaults to `--sink gl` (`glimagesink`, survives hotplug); `--sink wayland`
stays available for `fullscreen-output` placement.

### 6.5 Doc updates in this repo

* `PROTOCOL.md` Appendix B: the "headless Wayland output" hint can cite the
  concrete Hyprland mechanism and `ext-image-copy-capture` cursor sessions as
  the source for `cursor`/`cursorImg`.
* `README.md`: add a "Linux (in progress)" section pointing at `linux/PLAN.md`.
* `AGENTS.md`: add Linux dev-box notes (Hyprland Lua config, which GStreamer
  packages to install, UTM port-forward for Mac-sender tests).

---

## 7. Dev-VM setup checklist for Milestone 2

```sh
sudo pacman -S --needed gst-plugins-good gst-plugins-bad gst-libav gst-plugin-va \
                        gst-plugin-pipewire libva-utils wayland-utils
gst-inspect-1.0 avdec_h264 && gst-inspect-1.0 waylandsink   # both must exist
# UTM: Network → Port Forward: TCP host 9000 → guest 9000 (and UDP 9001 for M4)
# Mac sender: defaults write com.peetzweg.opensidecar.mac.debug host 127.0.0.1 ; port 9000
```

Test clips for `od-fake-sender` are one ffmpeg call away:

```sh
ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=60" -t 10 -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -tune zerolatency -x264-params "keyint=600:bframes=0" \
  -bsf:v h264_mp4toannexb -f h264 clip-1080p60.h264
```

(Confirm the file uses 4-byte start codes and carries SPS/PPS on every IDR; the
fake sender should re-insert them if the encoder emits them only once.)

---

## 8. References

* This repo: `PROTOCOL.md` (§1–§6, §8, Appendix A/B), `Shared/StreamReceiver.swift`,
  `tools/fake-receiver.swift`, `iOS/MetalVideoRenderer.swift`, `Mac/VirtualDisplay.swift`,
  `Mac/OpenSidecarMacApp.swift:187` (manual `-host`/`-port` endpoint).
* Issues: #284, #272, #271, #273, #243, #186, #84, #15.
* Hyprland: Lua-ification announcement <https://hypr.land/news/26_lua/>;
  ext-image-copy-capture issue <https://github.com/hyprwm/Hyprland/issues/9916>;
  `src/protocols/ImageCopyCapture.cpp`; Omarchy #6968 (`hyprctl keyword` no-op).
* xdg-desktop-portal-hyprland `src/portals/Screencopy.cpp`.
* wl-screenrec <https://github.com/russelltg/wl-screenrec>; Sunshine headless
  monitors on Wayland <https://github.com/LizardByte/Sunshine/pull/3783>.
* GitHub arm64 runners GA <https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/>.
* Asahi AVD progress <https://www.phoronix.com/news/Asahi-Linux-AVD-Firmware-M3>.
* cage kiosk compositor <https://www.hjdskes.nl/projects/cage/>.
