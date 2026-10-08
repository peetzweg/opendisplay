# Handoff: continuing the Linux port on the Intel Omarchy machine

Written 2026-09-22 for whoever (human or agent) picks this up on a bare-metal
x86_64 Omarchy install. Everything so far was built and verified on an
**aarch64 QEMU VM** running Omarchy/Hyprland 0.56.1 — no hardware codecs, no
LAN reachability. The Intel box unlocks exactly the things the VM could not
prove. Read `PLAN.md` for the full plan and decisions; this file is the
short "what to do next" list.

## 1. Where things stand (branch `linux-plan`, PR #298; issues #284 receiver, #299 sender)

| Piece | State | Verified how |
|---|---|---|
| `opendisplay-proto`, `opendisplay-session` | done | unit/property/loopback tests; CI green on x86_64 + aarch64 |
| `od-fake-sender` | done | TCP e2e tests (CI conformance run) |
| `od-receiver` | works, software decode | real picture on Hyprland via `glimagesink`; 30 fps from the fake sender; Linux→Linux session |
| `od-sender` | works, software encode (OpenH264), input injection | Linux→Linux session on the VM; `input-test` matches Hyprland `cursorpos` to the pixel |
| Arch `PKGBUILD` | authored, **never executed** | syntax check only |
| Hardware decode/encode (VA-API) | **untested** | nothing on the VM has it |
| Mac sender → `od-receiver` | **untested** | VM behind QEMU NAT |
| `od-sender` → iPad | **untested** | same |

## 2. First 15 minutes on the Intel box

```sh
git clone https://github.com/peetzweg/opendisplay && cd opendisplay && git checkout linux-plan
cd linux/packaging/arch && makepkg -si          # 1) first real run of the PKGBUILD; pacman pulls deps
vainfo                                          # 2) which VAProfileH264* entrypoints exist (VLD = decode, EncSlice = encode)
gst-inspect-1.0 vah264dec | head -5             #    present once gst-plugin-va is installed
gst-inspect-1.0 vah264enc vah264lpenc 2>/dev/null | grep -E 'Long-name|Rank'
```

If `makepkg` fails, fix the PKGBUILD (likely suspects: `--frozen` needing a
`Cargo.lock` refresh, `install` paths) and commit the fix — that is the
package Omarchy users will get.

## 3. Milestone 2 validation: the shipping Mac sender → `od-receiver`

```sh
RUST_LOG=info od-receiver                       # default: glimagesink window on the current output, mDNS on
```

- Same Wi-Fi as the Mac ⇒ the Mac's OpenDisplay app lists the Intel box like an
  iPad (Bonjour `_opensidecar._tcp`, TXT `id`/`pv=3`). Pick it.
- Watch the receiver log: the `stats {...}` line's `decoder` field says whether
  `vah264dec` (hardware) or `avdec_h264` (software) won; `renderFps` must track
  `fps`; `e2e50`/`e2e95` are capture→arrival ms once `offsetKnown` is true.
- Watch the Mac's log for `PHONE-STATS` (it echoes our `stats`).
- Try the Mac's quality presets, rotation of nothing (fixed panel), and pulling
  Wi-Fi to see the 5 s liveness → reconnect path.
- Fullscreen on a chosen monitor: `od-receiver --output <name>` selects which
  output's size goes into `hello`; actual fullscreen placement with the `gl`
  sink needs a Hyprland window rule on `title = "od-receiver"` (Hyprland ≥ 0.55
  uses Lua config — check the wiki for the current `hl.windowrule` shape).
  `--sink wayland` supports `fullscreen-output` directly but crashes on output
  hotplug with GStreamer ≤ 1.28.7 (see §6).

Collect: `vainfo` output, the first minute of `RUST_LOG=info` receiver log,
the Mac's `PHONE-STATS` lines, and a note of felt latency / stutter.

## 4. Milestone 3 validation: `od-sender` → the iPad

```sh
RUST_LOG=info od-sender run                     # discovers the first receiver on the LAN
RUST_LOG=info od-sender run --name iPad         # or filter by Bonjour instance name
```

- A headless output `od-<id>` appears to the right of your monitors, sized from
  the iPad's `hello` (panel pixels @ its refresh, scale from `hello.scale`);
  the iPad shows it; touch on the iPad moves/clicks the pointer on it.
- Expect **low fps at iPad resolution**: OpenH264 on the CPU is a placeholder
  (≈16 fps at 2732×2048 on 8 ARM vCPUs). The `sent … fps | encode p50 … ms`
  log line quantifies it. That number is the argument for Spike 0.
- The cursor is baked into the video for now (`--no-cursor` to hide it); the
  `cursor`/`cursorImg` messages and the UDP side channel are not sent yet.

## 5. Spike 0: hardware encode on this machine

`vainfo` listing an `EncSlice`/`EncSliceLP` entrypoint for H.264 is the go
signal. Decide, on this hardware, between:

1. **GStreamer**: push captured dmabufs into `appsrc` with `DMA_DRM` caps →
   `vapostproc ! vah264enc` (or `vah264lpenc`); measure capture→bitstream.
2. **ffmpeg-next**: VA-API via DRM hwframes, as wl-screenrec does.

The capture side already exists in `od-sender/src/capture.rs` but uses
`wl_shm` (CPU copy). The dmabuf variant needs `zwp_linux_dmabuf_v1` buffer
allocation (gbm) plus the session's `dmabuf_format` events — `PLAN.md §3.5`.
Also verify `zwlr_output_manager_v1.set_custom_mode` on the headless output
(compositor-agnostic sizing) while you are at it.

Interim software win: x264 (`x264enc` via `gst-plugins-ugly`, or libx264) is
3–8× faster than OpenH264 and would already make the iPad path usable.

## 6. Known issues you will meet

- **GStreamer `waylandsink` ≤ 1.28.7 segfaults on output hotplug** — any
  `wl_output` added/moved (the sender creating its display, docking a
  monitor) re-sends `wl_output.done`; `gstwldisplay.c:output_done()` stole its
  display pointer on the first `done` and dereferences NULL on the second.
  Repro: `gst-launch-1.0 videotestsrc ! waylandsink & hyprctl output create
  headless x`. Receiver defaults to `--sink gl` because of it. Report text and
  one-line fix: `PLAN.md §6.4`. File it upstream if not already done.
- `waylandsink`'s shm path only offers RGB formats; the pipeline has
  `videoconvert` after the latest-wins queue for that. On hardware with a
  VA decoder feeding a dmabuf-capable sink, try `--no-videoconvert` to keep
  zero-copy, and check `renderFps` still tracks `fps`.
- Capture is **damage-driven**: a static screen yields no frames. The sender
  keeps the last frame and re-encodes it as an IDR on `kf`/connect (§5.3).
  "No frames" is not a stall.
- Hyprland ≥ 0.55 is Lua-configured: `hyprctl keyword` is rejected; use
  `hyprctl eval 'hl.monitor({...})'` and verify with `hyprctl monitors -j`.
  `eval` says `ok` to inert code.
- `hello.scale` is inferred from the output (integer); `--scale` overrides.
  `maxEncodeWide/High` and `videoCaps` are not announced yet (needs the
  startup decode benchmark, M4).

## 7. Working conventions on this repo

- Commit as `peetzweg <839848+peetzweg@users.noreply.github.com>` — no
  Co-Authored-By or "Generated with" trailers of any kind.
- Conventional commit titles (`feat(linux):`, `fix(linux):`, …); the repo is
  squash-only and release-please reads the PR title — see the "Release note"
  in PR #298 before merging.
- `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -D
  warnings` and `cargo test --workspace` must pass; CI runs them on both
  architectures.
- Keep `PLAN.md` status lines current when a milestone moves; it is the
  source of truth for what is verified vs assumed.
