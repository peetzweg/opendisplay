# Native mirroring release procedure

An automated pass is necessary, not sufficient, for publication. Keep the last
known working installer available. Do not replace it with a partially validated
network fix.

1. Commit the intended changes to the fork's `main` branch. The **Optional native
   Screen Mirroring** workflow builds and tests pinned static dependencies,
   runs the complete suite and native CTest, builds the ZIP, and reruns tests
   from the extracted installer using its bundled runtime. Download its
   `native-mirror-installer-ARM64` Actions artifact, including **candidate.json**.
2. Freeze that ZIP. Extract it and run its bundled Node against its tests with
   `RUN_NATIVE_TESTS=1 RUN_VIRTUAL_TESTS=1 RUN_VIDEO_TESTS=1 RUN_SOAK_TESTS=1`.
   Save the complete TAP log. Run native CTest on the matching native build.
   `zsh Review.command --verify` also runs all groups and CTest from source;
   FFmpeg is required. A source-only pass does not replace extracted-ZIP testing.
3. Copy **evidence.template.json** to `release/results/<name>.json`. Record the exact ZIP
   checksum and source commit, complete TAP log path/hash and native results.
   Fill every physical row only after it was observed with this artifact.
   Include OS, device, network, time and the evidence reference. Do not publish
   private IPs, credentials, raw device inventory or private logs.
4. Run the release check from the helper directory:

   ```sh
   node scripts/check-release.js /absolute/path/candidate.json /absolute/path/evidence.json
   ```

   This reads the ZIP and TAP log and validates all required records. It makes
   no service, network or account changes. A failed check blocks publication.
5. Commit the completed physical record on the fork's `main` branch. Run
   **Publish validated native installer** from Actions on `main`, supplying the
   successful candidate run ID and the repository-relative evidence file path.
   The workflow checks the run's repository, branch, workflow, event and commit,
   downloads its artifact, reruns the extracted suite, regenerates automated
   evidence and enforces every physical row. Only then can the separate
   `native-mirror-release` environment job publish. It creates a draft, uploads
   the unchanged ZIP and evidence, verifies the downloaded checksum, then makes
   the prerelease visible. Existing tags/releases are never overwritten.
   Update the PR to that release.
   If any payload changes, rebuild and repeat artifact checks and the physical
   matrix. Never carry an old build's test result forward by version name alone.

## Required physical matrix

| Scenario | Required result |
| --- | --- |
| Fresh home LAN install, VPN off | Automatic phone setup and native-picker playback, without a developer IP override |
| Fresh restricted Wi-Fi install, VPN on | Installer-supported VPN setup, correct phone, fallback and real playback; no developer plist editing |
| Return home, VPN off | Existing LAN target works again without reinstallation or manual address changes |
| Home LAN, VPN on | LAN still wins; working session is not replaced by VPN |
| VPN unavailable | Clear bounded failure; no false success and no corruption of saved LAN settings |
| Upgrade from previous release | LAN target, optional fallback, identity and rollback behavior preserved |
| Repeated native connections | At least three fresh connections, each updating for 20 seconds |
| Rotation and audio | Three portrait/landscape cycles; selected Mac output stays audible |
| Background/resume | Home Screen for 15 seconds; reopen and confirm automatic playback recovery |
| Uninstall twice | First removal succeeds; repeating the documented command reports already uninstalled |

Rotation is a validation action, not an installation prerequisite. Keep Sidecar's
known iPad-first limitation separate from installation steps. Signing/platform
limitations must remain visible. Broader platforms remain unsupported/unverified
until tested; do not label them passed to complete the matrix.

The gate checks evidence consistency, not the truth of human observations.
The automated publication path is fail-closed. GitHub owners/write collaborators
can still use the manual release UI, and administrators can change workflows or
protection settings. Do not publish installer assets manually. Configure required
reviewers on the `native-mirror-release` environment for an additional approval
boundary. No automated check proves a human performed a physical test; the
committed record is an explicit attestation. This pipeline does not publish or
change the upstream author's official Mac/iOS releases.

The fork's environment is configured with `therealjosemaria` as a required
reviewer, administrator bypass disabled, and only branch `main` permitted.
Self-review remains allowed so the single repository owner can approve an
otherwise valid release. Administrators can still edit these settings; this is
not a repository-owner lockout. Other repositories must configure their own
environment before enabling this publication workflow.
