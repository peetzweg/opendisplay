# Changelog

## 0.0.15 — 2026-10-17

- Restore the AirPlay audio capability: disabling it can make macOS tear down
  the video route during an orientation update.
- Preserve the user's selected speakers or AirPods through a native Core Audio
  guard instead of suppressing that capability. The guard restores the previous
  available output only when this bridge becomes the default sound output.
- Test output preservation, manual output changes, unavailable devices and
  restoration failures with a simulated audio backend.
- Log audio/video teardown types without exposing pairing data.

## 0.0.14 — 2026-10-17

- Add a self-contained Mac installer app with bundled Node and native helpers.
- Install the background service without Homebrew, npm or compiler tools.
- Add per-user upgrades, failure rollback and removal from the installer window.
- Audit native dependencies and architecture; include third-party notices.
- Support Developer ID signing during packaging; local review builds are ad-hoc
  signed and are not notarized.


## 0.0.13 — 2026-10-17

- Dial discovered .local names through IPv4, matching the receiver transport
  checked by discovery; retain explicit Tailscale and IPv6 target behavior.

- Detect open OpenDisplay receivers through Bonjour during setup; select multiple
  receivers by name, ignore Mac-local aliases, and retain manual address fallback.

- Disable the advertised audio-support capability so this video-only bridge
  does not take over the Mac sound output. Live reconnect retained the selected
  output while the phone desktop continued working.

- Add a temporary reviewer launcher with dependency checks and a full build/test mode.
- Add a one-command installer that checks build dependencies, packages the source,
  installs it offline through npm and registers the persistent login service.
- Request fresh keyframes during startup so a static desktop can produce the
  receiver's video-driven playback reports; stop probing once playback confirms.
- Retain upstream's brief app-switch pause behavior instead of requiring
  continuous positive FPS from an idle display.
- Log first received/forwarded video and playback confirmation for diagnostics.
- Acknowledge every receiver hello, including rotation updates, without restarting AirPlay.
- Generate and persist distinct discovery identities for installations and review sessions.
- Document manual display arrangement and the distinction from automatic rotation.

## 0.0.12 — 2026-10-15

- Refresh native discovery automatically after network address changes or waking
  from sleep, once addresses have settled for at least three seconds.
- Defer discovery recovery until the current iPhone session ends.
- Add deterministic tests for network changes, settling, sleep and active sessions.
- Document the confirmed simultaneous-display workaround: connect iPad Sidecar
  first, then iPhone AirPlay. Starting Sidecar second was rejected by macOS.

## 0.0.11 — 2026-10-14

- Follow iPhone orientation changes through existing receiver hello updates.
- Resize the native AirPlay display using the `updateDisplayInfo` event, keeping
  the phone session open and debouncing repeated updates by 300 ms.
- Forward phone keyframe requests using AirPlay's `forceKeyFrame` event.
- Restrict the new event endpoint to same-Mac connections and close it on teardown.
- Add tests for panel validation, RTSP/plist encoding, reverse rotation, duplicate
  updates and session cleanup. Twenty-three tests pass.

Live prototype: the user confirmed a full-width landscape desktop, with AirPlay
video changing from 1288×2794 to 2794×1288. On installed v0.0.11, the user also
confirmed automatic resizing fills the phone in both portrait and landscape
without reconnecting.

## 0.0.10 — 2026-10-14

First public release of the native macOS Screen Mirroring bridge for the
OpenDisplay iPhone receiver.

- Install once with npm; a user LaunchAgent runs the receiver at login.
- Select iPhone in the native macOS Screen Mirroring menu.
- Portrait extended desktop, advertised at 1288 × 2796 and up to 60 FPS.
- Phone readiness check before AirPlay display setup.
- Fast rejection after two explicit connection refusals, with a 500 ms retry.
- Explicitly release pending native approval during shutdown.
- One macOS error for a closed phone app; a centered native dialog for playback failure.
- Conditional Tailscale setup and login handling.

Verified on one Apple Silicon Mac and iPhone 14 Pro Max. The user confirmed
portrait display, normal disconnect, and faster single-error behavior.
Twenty automated tests cover framing, video startup, readiness, native RTSP,
session lifecycle, installer configuration and Tailscale behavior.

Limits: iPhone OpenDisplay must remain visible; no audio, touch input, automatic
route selection, USB or direct peer-to-peer Wi-Fi. The picker uses a TV icon
because the tested MacBook discovery identity prevented AirPlay negotiation.
