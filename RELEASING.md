# Release checklist

Use this checklist for every release PR. Record the decisions in the release
PR even when the answer is "not affected" or "no mobile release required."
The goal is to know which existing installations were tested and whether users
must update one app, both peers, or neither.

## What the release workflow publishes

Merging an ordinary change into `main` updates the release-please PR. Merging
the release-please PR creates the version tag and GitHub release, then the
release workflow handles these artifacts:

| App | Target | Distribution when a release is created |
| --- | --- | --- |
| macOS sender | `OpenSidecarMac` | Notarized universal DMG on GitHub Releases and its Sparkle feed |
| macOS receiver | `OpenSidecarMacReceiver` | Notarized universal DMG on GitHub Releases and its separate Sparkle feed |
| iPhone and iPad receiver | `OpenSidecariOS` | One universal build uploaded to TestFlight |
| Linux sender (beta) | `linux/crates/od-sender` | `od-sender-{x86_64,aarch64}-unknown-linux-gnu.tar.gz` (static FFmpeg) on the same GitHub release |
| Linux receiver (beta) | `linux/crates/od-receiver` | `od-receiver-{x86_64,aarch64}.flatpak` on the same GitHub release |
| Android receiver | `Android/` (Gradle) | Signed `OpenDisplay-Android.apk` plus its `.sha256` on GitHub Releases, and an App Bundle uploaded to a Google Play testing track |

Both macOS apps are rebuilt and published on every release. The iPhone/iPad
build is uploaded to TestFlight on every release, but publishing it to the App
Store is a separate manual decision. A TestFlight upload does not update App
Store users. The Linux artifacts are built by `linux-release.yml`, which
`release.yml` calls with the new tag (job `build-linux`); it uploads them,
each with a `.sha256`, next to the DMGs and appends a "Linux (beta)" section
to the release notes. A failed Linux build does not hold back the Mac or iOS
jobs; re-run the failed jobs of that `Release` run (the upload uses
`--clobber` and the notes section is replaced, not duplicated).

## One version for every platform

Every app ships in lockstep under one version: the `vX.Y.Z` tag that
release-please creates. There are no per-platform tags.

- **macOS and iOS:** `release.yml` sets `APP_MARKETING_VERSION` from the tag
  (`X.Y.Z`) and the build number from the run number.
- **Linux:** release-please runs in manifest mode
  (`release-please-config.json`, `.release-please-manifest.json`) only so its
  `extra-files` can bump `linux/Cargo.toml` (`[workspace.package] version`)
  and the workspace crates in `linux/Cargo.lock` in the release PR. The
  tagged tree therefore builds with `cargo --locked`, and `linux-release.yml`
  refuses a tag that differs from the workspace version. `od-sender
  --version` and `od-receiver --version` print the tag. The Arch PKGBUILDs
  use the version as `pkgver`; after the release, run
  `linux/packaging/arch/opendisplay-sender/bump.sh X.Y.Z` (and the
  receiver's) and commit the checksum and `.SRCINFO`.
- **Android**: `versionName` is the tag, see below.

The manifest's version must always be the latest released version. Never edit
it by hand except when bringing this config to a branch: a branch that adds
it must carry the version of the latest `vX.Y.Z` release at merge time (and
`linux/Cargo.toml`/`Cargo.lock` the same), or release-please proposes a
version that already exists.

### Android receiver

The app in `Android/` takes its version from the tag; nothing in the tree
carries it. `versionName` is the tag without the `v`, and `versionCode` is
major*1000000 + minor*10000 + patch*100 + rebuild (1.27.0 becomes 1270000).
CI uses rebuild 0. A manual Play re-upload of the same version takes the next
free rebuild number, because Play never frees a versionCode once used.

An Android-only fix still goes out as `X.Y.Z` of the shared version (a
`fix(android):` commit), so the version a user reports names the same protocol
and feature set on every platform.

Every release builds two Android artifacts from the tag:

- **GitHub APK** (`build-android`): minSdk 21, so Android 5 and 6 devices
  work. Signed with our own app signing key from the `ANDROID_KEYSTORE_BASE64`,
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`
  secrets; without them the job builds but attaches nothing. APK installs do
  not update themselves.
- **Google Play bundle** (`upload-play`): minSdk 24 (Play rejects lower), signed
  with the upload key and uploaded to a testing track, like the iOS build goes
  to TestFlight. Releasing it to production is a manual promotion in Play
  Console. Without its secrets the job uploads nothing and logs a warning.

Play App Signing re-signs Play installs with a key Google generated, so a Play
install and a GitHub APK cannot update each other: switching channel means
uninstalling first.

One-time setup for the Play upload:

1. In Google Cloud Console, create a project, enable the **Google Play Android
   Developer API**, create a service account and download a JSON key for it.
2. In Play Console, **Users and permissions**: invite the service account's
   email with release rights for the OpenDisplay app only.
3. Add the secrets `PLAY_SERVICE_ACCOUNT_JSON` (the JSON file's contents),
   `ANDROID_UPLOAD_KEYSTORE_BASE64` (`base64 -i upload.jks`),
   `ANDROID_UPLOAD_KEYSTORE_PASSWORD` and `ANDROID_UPLOAD_KEY_ALIAS` (`upload`).
4. If the closed testing track is not Play Console's default one, set the
   repository variable `PLAY_TRACK` to its track name. The default closed
   track is `alpha`.

## Release impact record

Copy this section into the release PR and fill it in before creating the tag.
"Changed" means its source or assets changed. "Affected" includes behavior
changed through shared code or a peer's protocol behavior. "Required" means
users need that release to receive the fix or remain compatible.

| App | Changed? | Affected? | Release required? | Reason |
| --- | --- | --- | --- | --- |
| macOS sender | | | | |
| macOS receiver | | | | |
| iPhone receiver | | | | |
| iPad receiver | | | | |
| Android receiver | | | | |

- App Store production release: [ ] required [ ] recommended [ ] not required
- Reason for the App Store decision:
- Minimum useful update combination, such as "sender only" or "both peers":
- User-visible behavior or migration to mention in release notes:

## Compatibility and update order

- [ ] State whether the wire format, discovery, persistence, permissions, or
      saved display identity changed.
- [ ] Record `WireProtocol.version` and `WireProtocol.minSupportedPeer` before
      and after the change.
- [ ] Confirm that new fields and messages are additive and safely ignored by
      released peers, or document the deliberate incompatibility.
- [ ] Test or explicitly reason through every relevant pairing:
  - [ ] new sender with released iPhone/iPad receiver
  - [ ] released sender with new iPhone/iPad receiver
  - [ ] new sender with released macOS receiver
  - [ ] released sender with new macOS receiver
  - [ ] new sender with released Android receiver
  - [ ] released sender with new Android receiver
  - [ ] new sender with new receiver
- [ ] State whether a forced update is required. If yes, explain why graceful
      fallback is impossible and which versions are rejected.
- [ ] When peers must be released together, publish and verify the receiving
      app first. Do not enforce its new minimum version until it is available
      to users.
- [ ] Confirm that upgrading and downgrading preserve existing permissions,
      settings, display arrangement, and pairing state where applicable.

Prefer capability negotiation and fallback over forced updates. A protocol
version bump alone does not require rejecting an older peer; change the minimum
supported peer only when continuing would be incorrect or unsafe.

## Build and automated verification

- [ ] Generate the project from the committed configuration:

  ```sh
  xcodegen generate
  ```

- [ ] Run the macOS unit suite and sender compile check:

  ```sh
  xcodebuild test \
    -project OpenSidecar.xcodeproj \
    -scheme OpenSidecarMac \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
  ```

- [ ] Build the macOS receiver at its macOS 12 deployment floor.
- [ ] Build the generic iOS/iPadOS target. This is required when `Shared/`,
      `iOS/`, protocol code, assets, or project settings changed.
- [ ] Run the Android checks when `Android/` or the wire protocol changed:

  ```sh
  cd Android && ./gradlew testDebugUnitTest lintDebug assembleRelease
  ```
- [ ] For a release candidate, build both macOS apps in Release configuration
      and verify their executables contain `arm64` and `x86_64` with
      `lipo -info` or `file`.
- [ ] Confirm required GitHub checks pass on the final commit.
- [ ] Run `git diff --check` and confirm the working tree is clean.

## End-to-end verification

Choose the rows affected by the release and record the devices, OS versions,
resolution, refresh rate, transport, and app versions used.

- [ ] Extend mode connects, displays changing content, and accepts the cursor.
- [ ] Mirror mode connects and displays changing content.
- [ ] Best, Balanced, and Fast still select valid stream configurations.
- [ ] Rotation or receiver resolution changes reconfigure without stale video.
- [ ] Disconnect, reconnect, receiver quit/reopen, and sleep/wake recover without
      requiring a logout or computer restart.
- [ ] Wi-Fi works with useful frame latency and no unbounded queue growth.
- [ ] iPhone/iPad USB works if sender, transport, framing, or shared receiver
      code changed.
- [ ] Mac-to-Mac Thunderbolt Bridge or Ethernet works if connection migration,
      framing, or transport code changed.
- [ ] Pulling a cable falls back or fails clearly according to the documented
      behavior.
- [ ] The oldest supported macOS receiver launches on Intel hardware when
      receiver or shared code changed.
- [ ] The Android receiver connects over WiFi on a current device and on an
      Android 5.x device or emulator when `Android/` or the protocol changed.
- [ ] Existing App Store iPhone/iPad builds remain usable when no production
      mobile release is planned.

For performance-sensitive changes, compare the same scene before and after.
Record resolution and frame-rate selection, p50/p95 latency, encode time,
delivered FPS, dropped frames, cursor update rate/loss, and subjective behavior.
A clean average does not excuse severe tail latency or recovery failures.

## Packaging and publication

- [ ] Release notes say which apps users need to update and whether mixed
      versions remain supported.
- [ ] Version and build numbers are correct in all generated artifacts.
- [ ] The GitHub release contains both `OpenDisplay.dmg` and
      `OpenDisplayReceiver.dmg`, and the Linux tarballs and Flatpak bundles
      for x86_64 and aarch64 with their `.sha256` files.
- [ ] The release notes end with the "Linux (beta)" section, and
      `od-sender --version` from a tarball prints the release version.
- [ ] Both DMGs and contained apps pass signature, notarization, and Gatekeeper
      checks.
- [ ] The release contains `OpenDisplay-Android.apk` and its `.sha256`,
      `apksigner verify --print-certs` shows the release certificate (the same
      one as every earlier release), and the APK installs over the previous
      release without uninstalling.
- [ ] The sender and receiver Sparkle appcasts point to the correct DMGs and a
      released installation can update through each feed.
- [ ] The TestFlight upload finishes processing and launches on both an iPhone
      and an iPad when the mobile app is affected.
- [ ] If an App Store production release is required, update its notes and
      metadata, submit it after the TestFlight smoke test, and record whether
      release is manual or automatic after approval.
- [ ] Publish user-facing compatibility limits, required update order, known
      issues, and any one-time action users must take.

## After release

- [ ] Install through Sparkle on both macOS apps rather than testing only the
      downloaded DMGs.
- [ ] Repeat one representative new/new connection and one promised mixed-version
      connection using the published binaries.
- [ ] Check logs for connection loops, decode failures, encoder rejection,
      update-feed errors, or permission regressions.
- [ ] Confirm the download page, release assets, Sparkle feeds, and App Store or
      TestFlight version show the intended release.
- [ ] Run `bump.sh X.Y.Z` for both Arch packages and commit the result (it
      refuses to finish with a `SKIP` checksum).
- [ ] Keep the previous signed artifacts available as the rollback path and
      document any data or protocol state that prevents a safe downgrade.
