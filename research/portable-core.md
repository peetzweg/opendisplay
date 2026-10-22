# Portable core: Rust everywhere, or a common C core?

Research note, 2026-10-20. Inputs: the Linux plan documents of the time,
the `linux/` crates, issues #375, #241, #284, #15, #65, #66, #159, and the
external sources linked inline. Legend: **[V]** verified against a linked
source or the repo; **[I]** my inference; **[U]** unverified, needs the spike.

## 1. Bottom line

Keep Rust. Do not start a C17 core. The thing #375 wants from "a portable C
core" is a *C ABI* that Swift/ObjC, C++, Kotlin and C# shells can link, plus
toolchain reach to old macOS and to Windows. Rust already gives all of that
except one corner (macOS 10.10/10.11), and the portable part already exists:
`opendisplay-proto` + `opendisplay-session` are 2,798 lines of sans-I/O Rust
with 27 unit tests plus property tests and a loopback suite [V, repo]. A C
rewrite would re-implement verified code in the one language where a
network parser that accepts unauthenticated LAN input is least safe, for a
floor (10.10) that covers only 2007–2009 Macs.

Recommendation = **option C**: a Rust core exposing a stable C ABI (cbindgen),
consumed by (a) the existing Rust Linux binaries directly, (b) a small ObjC
shell for legacy Intel Macs, (c) a Windows sender/receiver whose *app* is Rust
(`windows-rs`) and whose virtual-display *driver* is the C++ IddCx sample,
which is the case in every language. The shipping Swift apps keep their own
Swift implementation; the ABI exists so they *can* adopt the core later, not
so they must.

## 2. Toolchain reach (the facts that decide this)

| Question | Rust (stable, 2026) | C17 + vendor toolchain |
|---|---|---|
| Oldest macOS a binary runs on | **10.12** on x86_64 (Tier 2 with host tools since 1.90; `MACOSX_DEPLOYMENT_TARGET` honoured, `rustc --print deployment-target`) [V: [platform-support](https://doc.rust-lang.org/nightly/rustc/platform-support.html), [apple-darwin](https://doc.rust-lang.org/nightly/rustc/platform-support/apple-darwin.html), [1.90 demotion](https://blog.rust-lang.org/2025/08/19/demoting-x86-64-apple-darwin-to-tier-2-with-host-tools)]. 10.7–10.11 dropped in **1.74** (Nov 2023); std calls `getentropy`/`clock_gettime`, so binaries do not load on 10.11 [V: [Rust blog](https://blog.rust-lang.org/2023/09/25/Increasing-Apple-Version-Requirements/), [MacPorts #69138](https://trac.macports.org/ticket/69138)] | clang `-mmacosx-version-min=10.10` with a current SDK still links (availability becomes weak imports) [I]. Xcode itself: 14–16.4 accept deployment target **10.13** minimum, Xcode 26 → 11, Xcode 27 → 12 [V: [Apple Xcode support](https://developer.apple.com/support/xcode/)]. So current *Swift* reaches 10.13 at best, and only until you move to Xcode 26. |
| 10.10/10.11 | Only with rustc ≤ 1.73 pinned. Our workspace is `edition = "2024"`, `rust-version = "1.85"` (edition 2024 shipped in 1.85, Feb 2025) [V: repo `linux/Cargo.toml`, [1.85 blog](https://blog.rust-lang.org/2025/02/20/Rust-1.85.0/)], so this means downgrading the portable crates' edition and pinning deps. Possible, not free. | Trivial. **The one real argument for C.** |
| Building for 10.12 from a modern Mac | Default deployment target *is* 10.12 on x86_64; set `MACOSX_DEPLOYMENT_TARGET=10.12` for the C/ObjC shim too, because `cc`/clang otherwise default to the SDK version and the link warns and takes the higher one [V: [rust#136113](https://github.com/rust-lang/rust/issues/136113)]. Rosetta runs the result on Apple Silicon for smoke tests [V: apple-darwin page]. | Same flag; Xcode GUI warns below 10.13 but compiles [V: forum reports in [Eclectic Light](https://eclecticlight.co/2024/07/25/will-updated-apps-still-run-on-older-macos/)]. |
| Cross-compile from Linux | Supported "using Clang, may require the macOS SDK" (`SDKROOT`); osxcross recipes exist [V: apple-darwin page]. Nice-to-have, not required: the release build can run on a GitHub macOS runner. | osxcross. |
| Windows | `x86_64-pc-windows-msvc` and `-gnu` Tier 1, **Windows 10+** since 1.78 (May 2024); Win7 only as Tier 3 `*-win7-windows-msvc` [V: [platform-support](https://doc.rust-lang.org/nightly/rustc/platform-support.html), [Win7 blog](https://blog.rust-lang.org/2024/02/26/Windows-7.html)]. `+crt-static` gives a self-contained exe on MSVC [V: [linkage](https://doc.rust-lang.org/reference/linkage.html)]. | MSVC/MinGW; the existing C++ PoC already ships a single self-contained exe [V: [opendisplay-win README](https://github.com/martinhoess/opendisplay-win)]. |
| Static linking on Linux | Pure-Rust → musl works; with FFmpeg/GStreamer we build natively per arch and link a minimal static FFmpeg + x264 (`linux-release.yml`, glibc ≥ 2.38 tarballs) [V: repo]. | Same linking story; no advantage. |

Windows 10+ is the floor for IddCx anyway (IddCx 1.0 = Win10 1607; 1.4 = 19H2; 1.5 = 20H1+) [V: [IddCx versions](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iddcx-versions)], so Rust's Win10 floor costs nothing.

**What 10.12 buys.** Sierra/High Sierra run on MacBook Late 2009+, MacBook Pro / Air / mini / Mac Pro Mid-2010+, iMac Late 2009+ [V: Apple list as reproduced by [BGR](https://www.bgr.com/tech/macos-high-sierra-how-to-download-compatible-macbook/); Apple's own page sp765 did not fetch]. Only 2007–2009 Macs are capped at 10.11. Fixing the floor at **10.12** and saying so (#375 already calls 10.10/10.11 "stretch") is the pragmatic cut; revisit only if testers with 2008 Macs show up (#159's "G4" is out regardless).

## 3. What the shared core actually is

Already in Rust, sans-I/O, tested [V, repo]:

- `opendisplay-proto`: framing (`Deframer`, `encode_frame`), §4 demux (`classify`, one isolated fn as PROTOCOL.md asks), control-message types, SPS parsing / parameter-set tracking, video-frame layout and telemetry-prefix stripping.
- `opendisplay-session`: `ReceiverSession` / `SenderSession` event→action state machines (liveness, clock offset, `kf` recovery, cursor sequencing, adopt-and-drop reset, `UpdateRequired`/`SenderOutdated`), `Now` abstraction so the host owns clocks.
- `od-sender/src/latest.rs`: the latest-wins one-slot queue (123 lines; trivially moves into the core).
- `od-fake-sender`: a conformance driver that can exercise *any* receiver over TCP, whatever language it is in.

Portable but I/O-bearing, optional for a second ABI tier: TCP/UDP loop (tokio), mDNS (`mdns-sd`, in-process responder/browser, pure-Rust deps, no system daemon) [V: [docs.rs](https://docs.rs/mdns-sd/latest/mdns_sd/)].

Inherently OS-native, never shared (table from #375/#65, checked):

| Platform | Virtual display (sender) | Capture (sender) | Encode / Decode | Present | Input |
|---|---|---|---|---|---|
| macOS 10.12–11 (legacy) | `CGVirtualDisplay` private classes: no availability annotations in Chromium's header dump except a 13.3 property; FreeDisplay lists it as "macOS 14+"; the earliest macOS that has the classes is **unverified** [V: [Chromium](https://chromium.googlesource.com/chromium/src/+/main/ui/display/mac/test/virtual_display_util_mac.mm), [FreeDisplay](https://github.com/huberdf/FreeDisplay)] [U below 14] | `CGDisplayStream` 10.8+, deprecated 14 (ScreenCaptureKit is 12.3+) [V: #241 table, OBS/Apple header deprecation notes] | VideoToolbox 10.8+ (`VTDecompressionSession`, `VTCompressionSession`) [V: #241 table] | `AVSampleBufferDisplayLayer` 10.8+ / OpenGL (Metal 10.11+) [V: #241] | `CGEvent` |
| macOS 12+ | shipping Swift sender/receiver, unchanged | | | | |
| Windows 10+ | **IddCx UMDF driver, C++/WDK, Session 0, built from the MS sample** [V: [IDD overview](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview)] | DXGI Desktop Duplication (Win8+) or Windows.Graphics.Capture | Media Foundation H.264 MFTs (NVENC/QSV/AMF hw) | D3D11 swap chain | `SendInput`, `InjectSyntheticPointerInput` for Pencil [V: opendisplay-win README] |
| Linux | Hyprland/Sway/KDE/GNOME backends | ext-image-copy-capture / PipeWire | FFmpeg x264 / VA-API; GStreamer | GStreamer sinks | wlr-virtual-pointer etc. |

The Windows driver dominates the Windows decision and is language-neutral: it must be C++ (WDK sample), it must be signed to install without test-signing, and signing means either attestation signing through Partner Center with an **EV certificate** (user-mode drivers are explicitly supported; no HLK; not Windows Update) or the free **SignPath Foundation** OSS route that `VirtualDrivers/Virtual-Display-Driver` and parsec-vdd's project use [V: [attestation](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-attestation), [driver-signing policy](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/kernel-mode-code-signing-policy--windows-vista-and-later-), [VDD README](https://github.com/VirtualDrivers/Virtual-Display-Driver), [opendisplay-win ROADMAP](https://github.com/martinhoess/opendisplay-win/blob/main/ROADMAP.md)]. martinhoess's PoC (C++, GPL-3, 181 kB of C++) proves the Windows→iPad path end to end on parsec-vdd and names the same linchpin [V: README/ROADMAP, GitHub languages API]. Windows *receiver* needs no driver: MF decoder + D3D11 + a window.

## 4. Options

**A. Rust everywhere, platform layers in Rust via bindings.** Fine on Windows (`windows` crate has `Win32::Media::MediaFoundation`, DXGI, D3D11 [V: [windows-docs-rs](https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/Media/MediaFoundation/index.html)]) and on Linux (done). On legacy macOS, `objc2-video-toolbox` exists (0.3.2, x86_64-apple-darwin listed) and `objc-sys` defaults to the same 10.12 floor as rustc [V: [docs.rs objc2-video-toolbox](https://docs.rs/objc2-video-toolbox/latest/objc2_video_toolbox/), [objc-sys](https://docs.rs/objc-sys/0.3.5)], but AppKit windows, LaunchAgent plumbing and `NSNetService` through objc2 is more unsafe glue than a 400-line ObjC file. Rejected only as a *rule*; pick per layer.

**B. C17 core, C ABI.** Reaches 10.10 with today's clang; consumable from everything. Costs: rewrite 2.8 k lines + tests (no proptest, hand-rolled JSON or a dep), lose memory safety on the one component that parses untrusted bytes, two cores to keep in sync with PROTOCOL.md (the Rust one stays because Linux is Rust), and contributor pool: all Linux contributors so far are Rust; the Windows PoC is C++, which links a C ABI equally well. Rejected.

**C. Rust core + stable C ABI (cbindgen).** `opendisplay-ffi` crate → `libopendisplay.a` + `opendisplay.h` ("creates C/C++11 headers for Rust libraries which expose a public C API" [V: [cbindgen](https://github.com/mozilla/cbindgen)]). Swift imports the header via a module map; C++ (opendisplay-win) includes it; Kotlin via JNI/UniFFI later if an Android author wants it. The ObjC/C++ shells are small, so the unsafe surface is the handful of extern fns, not the protocol. **Chosen.**

**D. Per-platform rewrites against PROTOCOL.md.** Status quo for Apple apps and the third-party Android receivers; proven to work (the spec is good enough that two Android receivers and a Windows sender exist). Keep it as the *permitted* path for people who want it; do not plan the legacy Mac or Windows work this way, because the receiver/sender state machines (clock sync, kf floor, adopt-and-drop, cursor seq, `UpdateRequired`) are exactly what each clean-room implementation gets subtly wrong.

Maintenance / safety / size [I]: one core, one test suite, `od-fake-sender` as the cross-language conformance harness. A `staticlib` of proto+session+serde_json with `panic=abort`, `opt-level="z"`, stripped is on the order of 1 MB; the receiver CLI for a legacy Mac is the core + ObjC shell + system frameworks, no bundled codec. Linux gets this for free: the binaries already link the same crates by path.

## 5. Target architecture

```
                 opendisplay-proto  ──┐
                 opendisplay-session ─┼─ Rust, sans-I/O, tested, cbindgen'd  ──► opendisplay.h / libopendisplay.a
                 latest-frame queue ──┘           (tier 1 ABI: bytes in / actions out, host owns sockets+clocks)
                 + optional tier 2 ABI: od_runtime_* (tokio TCP/UDP loop, mdns-sd) for CLIs/services

 Linux (Rust, as today)   legacy macOS 10.12+ (ObjC shell)        Windows 10+ (Rust app via windows-rs)
 od-sender / od-receiver  VideoToolbox decode, AVSampleBuffer-    receiver: MF H.264 MFT + D3D11 window
 GStreamer / FFmpeg       DisplayLayer, NSNetService (or tier 2   sender: DXGI dup / WGC + MF encode + SendInput
 Wayland backends         mdns), LaunchAgent, menu-bar status;    + IddCx UMDF driver (C++, MS sample fork,
                          sender only if CGVirtualDisplay exists  signed via SignPath or EV/attestation)
 macOS 12+ / iOS: shipping Swift apps, unchanged; may link the same header later (pv 4 typed framing is the natural moment)
```

ABI rules [I]: opaque handles (`od_receiver_t*`), `od_receiver_feed(bytes)`, `od_receiver_tick(now)`, `od_receiver_next_action(&action)` with a tagged-union `od_action` (send bytes / reset decoder / video AU / cursor / close); caller-provided buffers or explicit `od_free`; no callbacks into the host; version struct checked at init. mDNS on macOS goes through `NSNetService` in the shell (10.12 has it; `NWListener` is 10.14+ [V: #241 table]) rather than fighting `mDNSResponder` for port 5353 in-process [U]; on Windows and Linux `mdns-sd` in the core is right (Windows has no Bonjour by default; the PoC hand-rolled a query for the same reason [V: ROADMAP]).

## 6. Spikes (in order)

1. **Legacy Mac receiver on a 10.12 VM (1–2 days).** Build `opendisplay-ffi` for `x86_64-apple-darwin` with `MACOSX_DEPLOYMENT_TARGET=10.12` set for rustc *and* the `cc`/ObjC shim; check `otool -l | grep -A2 LC_VERSION_MIN_MACOSX`; a ~400-line ObjC `od-receiver-mac` (TCP via CFSocket/GCD, `NSNetService`, VideoToolbox → `AVSampleBufferDisplayLayer` fullscreen) driven by `od-fake-sender`, then by the real Mac sender. Run on 10.12 and 10.13 VMs (and an OCLP-free real machine if a tester has one). Same VM: `NSClassFromString(@"CGVirtualDisplay")` on 10.12/10.13/10.15/11 settles whether a legacy *sender* is even possible; if nil below 14, the legacy story is receiver-only and #375's scope is right.
2. **C ABI shape (1 day, Linux only).** Add `opendisplay-ffi` + cbindgen to the workspace; consume from a 100-line C program that passes the existing loopback/fake-sender conformance run; CI builds it on both arches. This fixes the header before anyone writes a shell against it.
3. **Windows (3–5 days, VM first, then a real PC).** Build the MS IddCx sample / Virtual-Display-Driver under test-signing; Rust sender using `windows` crate (DXGI dup + MF H.264) linked to the core; validate against the iOS receiver, and against `od-receiver` for a Windows receiver skeleton (MF decoder + D3D11). Decide in the same spike whether to adopt opendisplay-win's C++ MF/DXGI code (link it as a `cc`-built module behind the C ABI) instead of re-doing it in Rust: it is GPL-3 and already correct. Apply to SignPath Foundation on day one; it is the long pole, not the code.
