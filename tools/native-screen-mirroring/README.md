# Optional native Screen Mirroring sender

Experimental opt-in sender for [proposal #367](https://github.com/peetzweg/opendisplay/issues/367).
Open OpenDisplay on an iPhone and use macOS Control Center > Screen Mirroring
to extend the Mac desktop onto it. The OpenDisplay Mac sender is not required
for this mode. The existing Mac sender, USB, input and receiver paths remain
available without this helper or its dependencies.

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
discovery identities, network recovery, Tailscale preparation and launcher behavior.
Automated checks do not replace the physical Screen Mirroring test above.

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

This is a contained optional tool, not yet an embedded Swift app feature or a
signed/notarized standalone application. The core Swift targets and project.yml
are untouched. Packaging it with the official app, replacing the Node process,
and sharing device discovery are later architecture decisions for the maintainer.

Current limits:

- This installed revision was tested on one Apple Silicon Mac/iPhone 14 Pro Max
  pair over home Wi-Fi with Tailscale stopped: portrait reconnect, landscape and
  portrait resizing, and automatic resume after a brief app switch passed.
  All 39 automated tests passed from both source and the installed package.
  Tailscale-address playback and reconnect also passed on the home network.
  After disabling advertised audio support, live reconnect retained the selected
  Mac sound output while video worked. University Wi-Fi, Intel and other phones
  are not verified.
- Default advertised panel is 1288×2796; receiver hello updates adjust it once
  connected. Other device sizes require physical validation.
- Video only: no forwarded touch input or audio, no USB transport or automatic
  target selection. The receiver app must remain visible and unlocked.
- Phone setup uses Bonjour on the local network and saves its hostname.
  Tailscale targets can be supplied explicitly through IPHONE_HOST or the manual
  fallback. Automatic transport switching and remote Tailscale discovery are
  not implemented. Tailscale is used only when the target is a Tailscale address.
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
