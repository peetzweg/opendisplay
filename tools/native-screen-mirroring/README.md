# Optional native Screen Mirroring sender

Experimental opt-in sender for [proposal #367](https://github.com/peetzweg/opendisplay/issues/367).
Open OpenDisplay on an iPhone and use macOS Control Center > Screen Mirroring
to extend the Mac desktop onto it. The OpenDisplay Mac sender is not required
for this mode. The existing Mac sender, USB, input and receiver paths remain
available without this helper or its dependencies.

## Double-click installation (self-contained build)

**Apple Silicon Macs only. This review installer is not notarized.**

1. **Prepare your iPhone.** Connect it and your Mac to the same Wi-Fi. Keep OpenDisplay open on the unlocked iPhone, allow Local Network access.
2. **Download and unzip.** On the [download page](https://github.com/therealjosemaria/opendisplay/releases/tag/native-mirror-v0.0.17-arm64-review-20261018), expand **Assets** and download **iPhone-Native-Mirror-0.0.17-arm64.zip**. Double-click the ZIP to extract it.
3. **Open the installer.** Double-click **Install iPhone Native Mirror.app**. If macOS displays a warning, click **Done**. Open **Apple menu → System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway**. Authenticate if prompted, then click **Open**. See [Apple’s instructions](https://support.apple.com/en-au/102445).
4. **Install.** Click **Install**. Setup finds your phone automatically; no IP address is needed. When **Installation complete** appears, click **Done**.
5. **Connect your display.** Select **iPhone** in Mac **Control Center → Screen Mirroring** and choose **Extended Display**. Keep OpenDisplay open on the phone.

No Homebrew, npm, developer tools or Terminal command is needed. The service installs in your user account; macOS may request authentication for **Open Anyway**.

The installer can be closed or removed after setup. To upgrade, open a newer
installer and click Install; the discovery identity is retained. To uninstall,
open the installer and click **Remove**. Removal keeps saved phone settings.
The app installs only for the current user; the background service starts at
login. Reboot/login behavior still needs a physical test.

### Uninstall in one command

Paste this into Terminal. It stops and removes the installed background service and runtime; saved phone settings and logs are kept. No administrator password is needed.

```sh
if [ -x "$HOME/Library/Application Support/iphone-native-mirror/runtime/node" ]; then "$HOME/Library/Application Support/iphone-native-mirror/runtime/node" "$HOME/Library/Application Support/iphone-native-mirror/runtime/scripts/bundle-setup.js" --remove; else printf 'Already uninstalled\n'; fi
```

You can also reopen the installer and click **Remove**.

### Using an iPad and iPhone together

**Connection order matters: connect the iPad first, then the iPhone.**

1. Connect the iPad using Mac Control Center > Screen Mirroring and wait until
   its Sidecar desktop appears.
2. Open OpenDisplay on the unlocked iPhone.
3. Select **iPhone** in Control Center > Screen Mirroring.

On the tested Mac, connecting the iPhone first and then the iPad fails with
"Sidecar is not available while AirPlay Screen is active." The native Sidecar
log reports `SidecarErrorDisplayAirPlayBusy` (-453).
Newer source adds a **Connect iPad first** hint when that specific rejection is
visible in the Mac's live Sidecar/Control Center log while the iPhone is connected.
The hint gives the recovery steps below; it does not disconnect the phone or
replace macOS's own error. If log access is unavailable, the existing connection
continues normally. This extra hint has automated coverage; its real-device
trigger still needs validation and it is not in the published 0.0.17 ZIP.
In the controlled Control Center test, the iPhone stayed connected but the iPad
could not start. Independent connection in either order is **not supported by
this helper on the tested macOS build**; no startup-guard workaround is included.

To recover, disconnect **iPhone** in Control Center > Screen Mirroring, dismiss
the error, connect the iPad and wait for its desktop, then reconnect **iPhone**.
This recovery deliberately interrupts the iPhone display. Use Control Center
for these steps; System Settings > Displays was also observed to disconnect the
iPhone during a failed attempt to start Sidecar.

The working order, repeated iPhone rotations and selected Mac speakers/AirPods
were physically verified with version 0.0.15 on one Apple Silicon Mac running
macOS 26.6.1 (25G76). This does not establish compatibility on other macOS versions.

Current binary coverage is **Apple Silicon (arm64), macOS 14+ declared target**;
the physical test host runs macOS 26. The local review build is ad-hoc signed,
**not Developer ID signed or notarized**. macOS may block a downloaded copy.
A warning-free public release requires the maintainer's Developer ID signing
and Apple notarization; the project does not disable Gatekeeper or remove
quarantine. Intel builds require an x86_64 runtime/build and physical validation.

### Build the installer (developers only)

After installing the source-build prerequisites below, run:

```sh
node scripts/build-installer.js
```

This compiles the bridge and native setup UI, bundles the current Node binary,
checks every executable for external dylib dependencies and matching CPU
architecture, checks the macOS minimum of static dependencies and executables,
includes license notices and produces a ZIP in build/distribution.
The declared macOS 14 target is checked from build metadata; running on an
actual macOS 14 host still requires separate validation. Homebrew libraries built
for a newer macOS are rejected. Build libplist and OpenSSL static libraries with
`MACOSX_DEPLOYMENT_TARGET=14.0` and matching compiler/linker deployment flags,
then point the builder at their installation prefix and a fresh build directory:

```sh
MIRROR_DEPENDENCY_PREFIX=/path/to/compatible/prefix \
MIRROR_BUILD_DIRECTORY=build-macos14 node scripts/build-installer.js
```

The prefix must contain their headers, static libraries, pkg-config metadata
and license files. This is a developer build requirement; the resulting app
bundles its runtime and does not ask end users to install these tools.
The Node distribution LICENSE must be present beside its bin directory.
Set DEVELOPER_ID_APPLICATION to an Application signing identity to sign with
hardened runtime instead of ad-hoc signing. Notarize the ZIP with Apple's
notarytool, staple the app, verify it with spctl, and recreate the ZIP before
publishing a normal public release. Credentials are never stored by this tool.
CI produces ad-hoc review artifacts; it does not publish a notarized release.

## Review in three steps

1. Install Node 20+, Xcode Command Line Tools, CMake, pkgconf, libplist and
   OpenSSL 3. With Homebrew, `brew install node cmake pkgconf libplist openssl@3`
   installs the runtime and build libraries. `xcode-select --install` installs
   Apple's compiler tools if missing.
2. Double-click **Review.command** in this folder. It finds an open OpenDisplay
   receiver on the same network automatically; choose by name if several appear.
   The first run builds the helper. Keep OpenDisplay
   visible on the unlocked iPhone. If macOS blocks the downloaded command,
   review its source and run `zsh Review.command` from Terminal in this folder.
3. Select **OpenDisplay Review** in native Screen Mirroring, choose Extended
   Display, and move a window onto the phone. Turn off Portrait Orientation
   Lock and rotate the phone to test live resizing. Disconnect/reconnect from
   Screen Mirroring, then press Control-C in Terminal to stop the helper.

The review launcher does not install a login service, change app signatures,
reset permissions, or replace either app. Its discovery identity is stored only
in this folder's ignored `build/review-identity.json`. Delete `build/` to remove
review build products and identity. A failed connection or settled network
change ends a review run; open the launcher again to retry.

For the optional persistent service, use the standalone companion's installation
instructions: https://github.com/therealjosemaria/iphone-native-mirror.

## One-command installation for daily use

From this folder, run `zsh Install.command` or double-click Install.command.
It checks Apple's compiler tools, installs missing prerequisites with Homebrew,
detects the open phone through Bonjour, packages the source, and installs the persistent
login service. Homebrew and Xcode Command Line Tools are needed for automatic
setup. The package install uses a local archive and does not contact npm's
registry. Re-running the command upgrades the service while retaining its
saved identity. The installed service runs independently of this checkout.

The address is a LAN address on home Wi-Fi. Tailscale is optional for restrictive
networks; it is not required for ordinary home Wi-Fi. `IPHONE_HOST` can supply
an explicit address, including a Tailscale address, instead of local discovery.
If no receiver is found, setup offers manual entry with directions to find the
address on the phone itself. No router access is needed. Bonjour discovery may
be blocked on restrictive networks and does not enumerate Tailscale peers. `zsh Install.command --check` checks
prerequisites without changing the installed service.

For a temporary trial, use Review.command instead; it never registers a service.

## Release checks

Before publishing a new installer, follow [the release procedure](release/RELEASING.md)
and pass the artifact-specific release check. Home LAN, restricted Wi-Fi/Tailscale
and returning home without VPN are mandatory physical cases on the same ZIP.
The [19 October incident report](release/INCIDENT-2026-10-19.md) explains the
previous explicit-address versus automatic-setup coverage gap.

## Automated validation

```sh
zsh Review.command --check
zsh Review.command --verify
```

The first command checks dependencies. The second builds the native receiver
and error dialog, then runs the full test suite with temporary local network
listeners. It does not connect to a physical phone or install a service. CI runs
the same verification separately from the Swift application checks.

Coverage includes framing, video/keyframe recovery, repeated rotation handshakes,
readiness gating, fast SETUP rejection, native RTSP capabilities, session teardown,
discovery identities, network recovery, Tailscale preparation, audio output
preservation and launcher behavior.
Automated checks do not replace the physical Screen Mirroring test above.

### Virtual phone, without physical devices

From this directory, run `npm run test:virtual` (Node 20 or newer required).
This runs the actual Node bridge against a loopback TCP phone simulator and a
fake AirPlay producer. It uses temporary files and ephemeral ports; it does not
install, stop, or modify the installed service, or advertise a receiver on the LAN.
The tests need permission to open local TCP sockets and macOS's built-in `plutil`.

The eighteen scenarios check startup gating, partial and combined TCP messages,
six consecutive rotations with dimension updates on the existing connection,
forwarded video packets, temporary playback-report pauses, broken-connection
recovery, deselection/reselection, explicit receiver sleep, and missing playback.
They also reject malformed/oversized messages, unsupported versions and playback
claims before a handshake, and exercise delayed handshakes, a 31-message rotation
burst, twelve connection cycles, and slow-receiver backpressure.
Video packets are synthetic H.264-shaped fixtures, not decodable video. Playback
statistics are simulated. Passing these tests does not establish actual rendering,
audio output, Wi-Fi/Tailscale behavior, or native Screen Mirroring/Sidecar compatibility.

For physical follow-up, record the OS and installer version, connection order,
whether the first display remains continuously visible, whether the second starts,
and any error. Run both rows independently, starting with both displays disconnected:

| Connection order | Required result | Current physical evidence |
| --- | --- | --- |
| iPad Sidecar, then iPhone | Both update; iPad is never interrupted | Previously observed working |
| iPhone, then iPad Sidecar | Both update; iPhone is never interrupted | Blocked by Sidecar's AirPlay-busy startup guard on the test Mac |

After both connect, check repeated rotation, chosen audio output, and receiver
background/resume. The virtual suite does not bypass Apple's startup guard or
count either connection-order requirement as passed.

With FFmpeg available, `npm run test:video` adds three tests that encode valid
H.264, forward it through the real bridge, and decode the result. They check
resolution changes, actual decode recovery after a dropped socket, corrupt video
that must not confirm playback, and startup recovery from missing keyframes.
Wire-format assertions also match the stock iPhone's four-byte Annex-B parser.
These tests exercise the real Node bridge with a simulated AirPlay producer.
`npm run test:soak` adds a sustained run with 120 fresh resize events and twelve
forced TCP reconnections, checking continued video forwarding. This uses synthetic
video packets; the separate video suite checks actual decoding. Set
`RUN_VIDEO_TESTS=1 RUN_SOAK_TESTS=1` for direct Node test runs.
`Review.command --verify` now includes both suites and native CTest by default. The video suite requires the developer's FFmpeg installation.

For a native-picker test against a virtual phone, developers with FFmpeg at
`/opt/homebrew/bin/ffmpeg` can run `node scripts/live-virtual-phone.js`, then select
**Virtual iPhone Test** in native Screen Mirroring. This uses the real native
AirPlay receiver and bridge, feeds video to FFmpeg, and reports playback feedback
only after frames decode. It sends a rotation hello every ten seconds and stops
after three minutes. It does not install a service or save video. The installed
iPhone bridge stays separate. FFmpeg is a developer test dependency only.

`LIVE_SELF_TEST=1 node scripts/live-virtual-phone.js` checks that same TCP/decoder
path using twenty generated H.264 frames, without starting AirPlay. A self-check
pass does not mean a native picker connection occurred. The live test must show
both a connection and decoded frames; manually verify the iPad remains updating
through startup and rotation before recording a coexistence pass.
The live tester returns nonzero if no connection occurs, video never decodes,
the connection drops, or decoded video does not confirm both orientation changes.
Its AirPlay pairing UUID is separate from the installed receiver, so test discovery
does not reuse the installed endpoint's identity. The default installed UUID is
unchanged. Native automated receiver tests use separate UUIDs as well.

To observe display registration during a physical test, compile the read-only
monitor with `clang native/test-display-monitor.c -framework ApplicationServices
-framework CoreFoundation -o /tmp/opendisplay-display-monitor`, then run
`/tmp/opendisplay-display-monitor 180`. It records timestamped active IDs and
sizes every 100 ms, alongside best-effort CoreGraphics reconfiguration callbacks.
The command-line process did not reliably receive callbacks on the test Mac.
Polling can miss shorter interruptions, and display registration does not prove
uninterrupted rendered content on the physical iPad.

## Implementation and boundaries

```text
macOS Screen Mirroring → UxPlay receiver core (C)
                      → Node framing/session bridge
                      → existing OpenDisplay iPhone receiver
```

The C helper and Node bridge exchange framed video and lifecycle events through
pipes. Independent mDNS advertisement makes the same-Mac endpoint discoverable.
The launcher restricts incoming AirPlay sessions and rotation event connections
to same-Mac addresses. H.264 is forwarded without a second encode. Rotation uses
the receiver's existing hello/panel messages and AirPlay updateDisplayInfo.
macOS requires the advertised audio capability to keep the route active during
resizing. A native Core Audio guard remembers the user's selected output and
restores it if macOS selects this bridge. Audio is not forwarded to the phone.

This is a contained optional tool, not yet an embedded Swift app feature or a
signed/notarized standalone application. The core Swift targets and project.yml
are untouched. Packaging it with the official app, replacing the Node process,
and sharing device discovery are later architecture decisions for the maintainer.

Current limits:

- The tested 0.0.15 review candidate passed **88 automated tests**, with no
  skips, from source and from its extracted installer using the bundled runtime.
  These cover native protocol handling, decoded H.264, installer rollback, and
  a simulated 120-rotation / twelve-reconnect run; they do not prove every
  physical-device or operating-system combination.
- On one Apple Silicon Mac running macOS 26.6.1 and an iPhone 14 Pro Max over
  home Wi-Fi with Tailscale off, automatic installation found the phone without
  an IP address. After fully reopening OpenDisplay, the desktop remained
  connected, repeated rotations filled both orientations, and sound stayed on
  the selected Mac speakers/AirPods. An earlier startup stayed on the waiting
  screen and recovered after reopening the receiver; startup reliability and
  receiver recovery still need more testing.
- With iPad Sidecar connected first, both displays worked through repeated phone
  rotations. iPhone-first then iPad fails with Sidecar's AirPlay-busy startup
  guard. Follow the [connection order and recovery steps](#using-an-ipad-and-iphone-together).
- Explicit Tailscale-address playback passed in earlier physical tests; this
  final candidate's new physical validation was over home Wi-Fi with Tailscale
  off. University Wi-Fi, Intel and other phone models are not verified.
- Default advertised panel is 1288×2796; receiver hello updates adjust it once
  connected. Other device sizes require physical validation.
- Video only: no forwarded touch input or audio, no USB transport or automatic
  target selection. The receiver app must remain visible and unlocked.
- Phone setup uses Bonjour on the local network and saves its hostname.
  Tailscale targets can be supplied explicitly through IPHONE_HOST or the manual
  fallback. Automatic transport switching and remote Tailscale discovery are
  not implemented. Discovered .local names are dialed over IPv4, matching
  discovery checks. Tailscale is used only when the target is a Tailscale address.
- A TV icon is used because the tested MacBook AirPlay identity failed negotiation.
- Physical left/right placement is not sensed. Use System Settings > Displays >
  Arrange. macOS may remember different positions for portrait and landscape.
  Set the desired side once in each orientation; on the tested Mac, subsequent
  rotations retained the same side. This is saved placement, not physical sensing.
- The phone leg uses the current plaintext pv 3 protocol. Any integration must
  track encrypted pairing in #16; the local AirPlay restriction does not encrypt
  the phone connection.
- Login/reboot and real network-switch recovery need additional physical testing.
  The persistent service handles restarts; the temporary review runner does not.

## Provenance

The implementation comes from Jose Mosciaro's GPL-3.0-or-later
[iphone-native-mirror](https://github.com/therealjosemaria/iphone-native-mirror)
prototype at `844b1e8`, plus the review launcher, unique discovery identities and
rotation-handshake correction prepared for this contribution.

UxPlay core is vendored from FDH2/UxPlay commit
`ec203121355220dd90278a369eeabb0b8ba4f14a`. Its license and original notices are
retained; local changes are listed in `vendor/uxplay/PATCHES.md`. Original
OpenDisplay authorship is unchanged. See the local LICENSE and the upstream
PROTOCOL.md and COMPATIBILITY.md for the receiver contract.
