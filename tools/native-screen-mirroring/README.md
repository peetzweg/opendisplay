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
2. Double-click **Review.command** in this folder and enter the phone's Wi-Fi
   or Tailscale IP address. The first run builds the helper. Keep OpenDisplay
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

- Physical playback coverage is one Apple Silicon Mac/iPhone 14 Pro Max pair
  from the companion prototype. This prepared revision still needs a physical
  playback test; Intel and other phones are not verified.
- Default advertised panel is 1288×2796; receiver hello updates adjust it once
  connected. Other device sizes require physical validation.
- Video only: no forwarded touch input or audio, no USB transport or automatic
  target selection. The receiver app must remain visible and unlocked.
- Manual target address; Tailscale is optional and used only for a Tailscale
  address. Bonjour discovery is for the AirPlay endpoint, not phone selection.
- A TV icon is used because the tested MacBook AirPlay identity failed negotiation.
- Physical left/right placement is not sensed. Use System Settings > Displays >
  Arrange. Rotation is automatic; macOS owns desktop arrangement in this mode.
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
