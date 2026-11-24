# Local macOS development

Keep the development app identities stable. macOS TCC associates Screen
Recording and Accessibility grants with the bundle identifier and signing
requirement; changing either creates stale or duplicate permission entries.

- Sender Debug bundle ID: `com.peetzweg.opensidecar.mac.debug`
- Receiver Debug bundle ID: `com.peetzweg.opensidecar.mac.receiver.debug`
- Keep Debug builds separate from the release bundle IDs.
- Build the sender into `build/Build/Products/Debug/OpenDisplay Dev.app` and
  launch it with `./run.sh`. The script normalizes an ad hoc build's designated
  requirement before launch. Do not rebuild or re-sign it after granting Screen
  Recording during a test session.
- If the Debug sender's permission row is stale, quit it, run
  `tccutil reset ScreenCapture com.peetzweg.opensidecar.mac.debug`, launch the
  unchanged app, use its Grant button, and restart it once.

The Intel receiver test host is available as `ssh imac`. Deploy the x86_64
Debug receiver to `~/Applications/OpenDisplay Receiver Dev.app`; do not replace
the release receiver app. A windowed receiver is sufficient for protocol,
encode, and decode validation. Use its fullscreen video window for end-to-end
latency, presentation, scaling, and visual-quality measurements.

# Linux development (`linux/` workspace)

The Rust workspace builds natively per architecture; see `linux/README.md`.

- Omarchy build/runtime packages: `pkgconf gst-libav gst-plugins-good
  gst-plugins-bad gst-plugin-va gst-plugin-pipewire libva-utils` (headers ship
  with the main `gstreamer`/`gst-plugins-base-libs` packages). Without
  `pkgconf`, build with `--no-default-features` and use `--sink none`.
- Protocol-only loop, no display needed:
  `od-receiver --listen 127.0.0.1:9100 --sink none` and
  `od-fake-sender --connect 127.0.0.1:9100 --clip linux/testdata/clip-320x180-30.h264 --fps 60`.
- Hyprland >= 0.55 is Lua-configured: `hyprctl keyword` is rejected; use
  `hyprctl eval 'hl.monitor({...})'` and verify with `hyprctl monitors -j`.
- The dev VM is behind QEMU user-mode NAT (`10.0.2.x`): a Mac sender on the LAN
  needs a UTM port forward to guest 9000 plus the sender's `-host`/`-port`
  manual endpoint, or the VM switched to bridged networking for Bonjour.

# Release PRs

Before merging a release-please PR, post the filled-in "Release impact
record" from RELEASING.md as a comment on that PR. release-please rewrites the
PR body whenever `main` changes, so the record lives in a comment. Build each
row from `git diff vX.Y.Z origin/main` (the last tag), not from the changelog
alone: a peer whose code did not change can still be affected through the
sender or the protocol. Name the devices and version pairings that were
tested, say plainly which were only reasoned through, and state whether the
App Store build is required, recommended or not required. Example: the 1.30.0
record on https://github.com/peetzweg/opendisplay/pull/439.
