# Experimental workaround for Best quality on a 5K Mac receiver

This branch proposes a sender-side workaround for [issue #271](https://github.com/peetzweg/opendisplay/issues/271). It preserves a 4096×2304 stream and reduces the nominal encoder frame rate to 55 fps. It does **not** enable native 5120×2880 streaming or guarantee 55 delivered fps.

## What changes

- Calculate a conservative H.264 rate from the encoded raster's 16×16 macroblocks and the Level 5.2 macroblock-rate budget.
- Use that rate for `ExpectedFrameRate` and gate submissions at the shared encoder entry point, including replay and reconnect paths.
- Keep the latest skipped frame and use the existing 30 ms replay timer, so an isolated final screen change is not lost when capture goes idle.
- Preserve the existing unpaced 60 fps behavior for smaller rasters that fit the budget.

For 4096×2304, there are 36,864 macroblocks per frame. The budget of 2,073,600 macroblocks/second allows 56 whole frames/second; this workaround leaves one additional frame/second of headroom and selects 55. This is a conservative workaround for the reported symptom, not general hardware-capability detection.

## Build on the sender Mac

Requirements: a Mac running macOS 14 or later, full Xcode with its license and required components initialized, Git, and XcodeGen. If Homebrew is installed, install XcodeGen with `brew install xcodegen`.

1. Download this branch into a new folder:

   ```sh
   git clone --branch fix/h264-large-stream-pacing --single-branch https://github.com/vipstanley/opendisplay.git opendisplay-5k-workaround
   cd opendisplay-5k-workaround
   ```

2. Generate and build the sender:

   ```sh
   xcodegen generate
   xcodebuild build \
     -project OpenSidecar.xcodeproj \
     -scheme OpenSidecarMac \
     -configuration Debug \
     -destination 'platform=macOS' \
     -derivedDataPath build \
     CODE_SIGNING_ALLOWED=NO
   ```

   Xcode will fetch the upstream Sparkle dependency on the first build. If this fails during package resolution, resolve the download/network error before retrying; it is separate from the video patch.

3. Disable automatic updates in this experimental build and sign it for local use:

   ```sh
   APP="$PWD/build/Build/Products/Debug/OpenDisplay Dev.app"
   /usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$APP/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$APP/Contents/Info.plist"
   codesign --force --deep --sign - "$APP"
   codesign --verify --deep --strict "$APP"
   ```

4. Quit the normal OpenDisplay sender, then launch this build:

   ```sh
   open "$APP"
   ```

   This is a locally built, ad-hoc-signed application, not an official notarized release. The Debug app has its own bundle identity, so macOS may request Screen Recording, Accessibility, or Local Network permission again. Grant the permissions needed for your use through System Settings.

5. Keep the existing OpenDisplay Receiver running on the iMac. Connect from the sender with **Extend → Best (native)**. No receiver rebuild is needed for this workaround.

The sender log is at `~/Library/Logs/OpenDisplay Dev/opendisplay.log`. For a 4096×2304 stream, look for:

```text
H.264 L5.2 rate cap: 4096x2304 -> 55fps
encoder ready: 4096x2304 H.264 18Mbps fps=55 quality=best lowLatencyRC=true
```

To revert, quit OpenDisplay Dev and open your normal OpenDisplay sender. Balanced remains the existing workaround if this experimental branch does not work on your hardware.

## Validation and limitations

- The initial prototype was built on an M4 MacBook Pro running macOS 26.3 with Xcode 26.6 and used with a 2015 5K iMac over Wi-Fi. It established a 4096×2304 extended stream, sustained approximately 35–40 delivered fps in the observed intervals, and reconnected successfully.
- The prototype still logged isolated `nil buffer despite noErr` events at startup/reconnect. The sustained near-every-frame rejection pattern did not recur during the short observed sessions. This is not a claim of zero dropped frames or a long-duration soak test.
- This public revision additionally routes replay/reconnect frames through the limiter and schedules delivery of a deferred final update. It has been built and has passed all 44 macOS unit tests, including ten new rate-policy tests. The completed public revision has **not yet had a fresh end-to-end receiver test**; the above hardware measurements belong to the initial prototype.
- Unit tests cover rate selection, macroblock rounding, a 60 Hz source paced to 55 fps, deferred-frame eligibility, long idle gaps, reset, invalid timestamps, early admission, and duplicate prevention near a later slot. They do not emulate VideoToolbox or prove actual timer delivery to a physical receiver.
- The workaround does not change receiver decode limits, codec, bitrate, or network handling. Lowering a nominal frame rate does not guarantee compatibility with every encoder, display, or transport.

## Reproduce the automated tests

After generating the project:

```sh
xcodebuild test \
  -project OpenSidecar.xcodeproj \
  -scheme OpenSidecarMac \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO
```

Feedback is welcome on issue #271 and the linked draft PR. Please include sender/receiver models, macOS versions, transport, selected quality, encoded resolution, target fps, and whether repeated nil-buffer errors persist. Remove device names, network addresses, and other personal information before sharing logs.
