# HEVC 5K handoff: M5 Pro sender trial

This branch (`feat/hevc-5k-mac-receiver`) adds an opt-in HEVC stream for a Mac
sender and Mac receiver. The aim of the next test is to find out whether the
M5 Pro can send the 2017 5K iMac's **Default** desktop at 5120×2880 and close
to 60 fps. The iMac already decoded and displayed that stream from an M1 Pro;
the M1 Pro encoder limited it to about 23 fps.

## What is implemented

- Both Debug apps must have `hevcExperimental=YES`. The Mac receiver advertises
  HEVC only when VideoToolbox reports hardware decode support. The sender
  selects HEVC only for a Mac that explicitly advertises it. iOS and older
  receivers keep the H.264 path.
- HEVC uses VideoToolbox hardware encoding, Annex B video with VPS/SPS/PPS on
  keyframes, and a `streamConfig` announcement before video. It can preserve
  the full 5K raster instead of applying H.264's 4096×2304 limit.
- The sender permits two in-flight HEVC encodes. One limited 3072×1728 to
  roughly 34–42 fps; three reached only 49–52 fps and increased latency and
  stalls, so two is the measured compromise. H.264 remains at one.
- This is an experimental preference, with no UI switch or automatic fallback
  if HEVC encoder creation fails. Disable the preference on either Mac to
  return to H.264. Protocol details are in [PROTOCOL.md](PROTOCOL.md).

## M1 Pro baseline, 19 September 2026

Sender: MacBookPro18,3 with M1 Pro. Receiver: iMac18,3 (2017, Radeon Pro 570),
fullscreen for visual judgment. The USB-C cable created a direct peer network
link (`en6` on the sender, `en4` on the iMac, `169.254.x.x` addresses). It was
not a Thunderbolt link. A moving 1200×600 window updated at 60 Hz; the sender
captured about 59–60 fps. These are live receiver rates, not the requested
stream rate:

| iMac display setting | Sender quality | HEVC video | Received fps | Median encode time |
| --- | --- | --- | ---: | ---: |
| 2560×1440 Default | Best | 5120×2880 | ~23 | 36–37 ms |
| 2048×1152 | Best | 4096×2304 | ~31–34 | 24–25 ms |
| 2048×1152 | Balanced | 3072×1728 | ~45–49 | ~15 ms |
| 2048×1152 | Fast | 2048×1152 | 59–60 | 8–9 ms |

The 5K Default image was visibly sharper than H.264 Default and at least as
sharp as the smaller iMac display settings, according to the person viewing
the iMac. The Fast stream was visibly softer. Network drops were zero in the
5K, Best 4K, and Fast 2K runs. Encoder drops rose at larger rasters. An H.264
Best 4096×2304 run delivered about 28–30 fps. A faster cable alone therefore
does not address this pair's bottleneck.

The M5 Pro would need a substantial throughput gain: 37 ms median encode time
must fall toward the 16.7 ms frame interval, and delivered 5K rate must rise
from ~23 to ~60 fps. Apple lists hardware HEVC encode for M5 Pro but does not
publish a 5K live-encode rate. Measure it; do not infer the result from CPU or
GPU benchmarks.

## Bring up the M5 Pro

1. Get this branch on the M5 Pro. It needs Xcode with the macOS SDK. Build the
   sender **on that Mac** so its local Debug app identity and TCC grants are
   straightforward:

   ```sh
   git fetch origin
   git switch --track origin/feat/hevc-5k-mac-receiver
   xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac \
     -configuration Debug -derivedDataPath build \
     CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
   defaults write com.peetzweg.opensidecar.mac.debug hevcExperimental -bool YES
   defaults write com.peetzweg.opensidecar.mac.debug quality -string best
   ./run.sh
   ```

2. Grant Screen Recording to **OpenDisplay Dev** when prompted. `./run.sh`
   normalizes the ad hoc app's designated requirement before launch. Restart
   the unchanged app once after granting. Do not rebuild or re-sign it during
   that permission test session. If the Debug row is stale, quit the app, run
   `tccutil reset ScreenCapture com.peetzweg.opensidecar.mac.debug`, launch the
   unchanged app, use its Grant button, and restart once. The release sender's
   bundle ID and permissions are separate.

3. Use the existing x86_64 **OpenDisplay Receiver Dev.app** on the iMac at
   `~/Applications/OpenDisplay Receiver Dev.app`. It is already installed from
   this branch with HEVC enabled. Run `ssh imac 'open "$HOME/Applications/OpenDisplay Receiver Dev.app"'`
   if it is closed. If `ssh imac` is not configured on the M5 Pro, configure
   that alias or substitute the iMac's SSH host. Quit any other receiver that
   occupies TCP port 9000. Keep the release receiver app installed separately.

4. Quit or disconnect the old M1 Pro sender before connecting the M5 Pro; the
   receiver serves one sender at a time. Connect the cable, then choose the
   iMac's discovered row in the M5 Pro sender. The sender may first dial WiFi
   and then migrate the same session to the direct cable address. Its log must
   eventually show `wired=true direct=true` and a `169.254.x.x` peer. The
   receiver's `transport: "WiFi"` statistic currently labels any non-loopback
   TCP link as WiFi, including this USB peer network; use the sender path log
   to verify the physical route. Avoid a manual `host` override unless
   discovery fails: it adds a second UI row for the same iMac.

5. On the iMac, select **Default (2560×1440)** in Display Settings. Wait for
   `stream selected: HEVC 5120x2880` in the sender log and `HEVC format
   description built: 5120x2880` in the receiver log. Use the receiver video
   window in fullscreen for sharpness and presentation judgment. A windowed
   receiver is sufficient for protocol and encode/decode checks.

## Repeatable measurement

After the 5K stream settles, run this on the M5 Pro sender:

```sh
swift tools/hevc-motion-test.swift
```

It finds the single OpenDisplay virtual screen by vendor/product ID and draws
moving bars there at 60 Hz. If there are multiple OpenDisplay screens, pass
the desired display ID; the tool prints the available IDs. Let it run for at
least 20 seconds, ignore the first report after a mode change, then stop it
with Control-C. Read the sender log:

```sh
rg 'connection path|stream selected|encoder ready|PHONE-STATS' \
  "$HOME/Library/Logs/OpenDisplay Dev/opendisplay.log" | tail -n 25
```

`PHONE-STATS.fps` is received frames per second; `capFps` is sender capture
rate; `enc50` is median encode time in milliseconds. The appended `mac enc↓`
and `net↓` counters are drops during that reporting window. Record several
steady windows, not one peak. A useful 5K/60 result would sustain roughly
58–60 received fps with near-zero drops and no visible stutter. Compare the
2048×1152 iMac display setting at Best, then restore Default if desired.

For the 2017 iMac, `ssh imac` exposes the receiver log at
`~/Library/Logs/OpenDisplay Receiver Dev/opendisplay.log`. On the old M1 Pro,
an offline simple-frame decode probe reached well over 60 fps at 5K, and the
live receiver built the 5K HEVC format without error. That does not guarantee
every frame will present smoothly at 60 fps; fullscreen live testing decides.

## If the iMac receiver must be rebuilt

The iMac has an x86_64 CPU. From a Mac with this branch and Xcode, build and
deploy **only the Debug receiver**; never replace the release app:

```sh
xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMacReceiver \
  -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=x86_64' \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
codesign --force --sign - \
  --requirements '=designated => identifier "com.peetzweg.opensidecar.mac.receiver.debug"' \
  --entitlements MacReceiver/OpenSidecarMacReceiver.entitlements \
  'build/Build/Products/Debug/OpenDisplay Receiver Dev.app'
```

Quit the iMac's Debug receiver, then deploy the app while preserving the
spaces in its name:

```sh
ssh imac 'rm -rf "$HOME/Applications/OpenDisplay Receiver Dev.app"'
tar -cf - -C build/Build/Products/Debug 'OpenDisplay Receiver Dev.app' \
  | ssh imac 'tar -xf - -C "$HOME/Applications"'
ssh imac 'codesign --verify --deep --strict "$HOME/Applications/OpenDisplay Receiver Dev.app"'
ssh imac 'defaults write com.peetzweg.opensidecar.mac.receiver.debug hevcExperimental -bool YES; open "$HOME/Applications/OpenDisplay Receiver Dev.app"'
```

The stable Debug IDs are `com.peetzweg.opensidecar.mac.debug` and
`com.peetzweg.opensidecar.mac.receiver.debug`. [AGENTS.md](AGENTS.md) has the
local signing and TCC rules. Earlier testing accidentally copied a receiver
into an `~/Applications/OpenDisplay/Contents` sibling because an `rsync`
destination with spaces was not quoted; that stray copy was removed. Use the
quoted `tar` deployment above.

## Verification already completed and remaining work

- On the M1 Pro, 23 stream-configuration tests passed. The sender Debug app
  built and ran; the x86_64 receiver Debug app built, signed, deployed, and
  decoded live HEVC at 2048, 4096, and 5120 pixel widths.
- `git diff --check` passed. The iOS build was unavailable on that Mac because
  its Xcode installation lacked the required iOS 26.5 platform. Shared
  receiver code is compiled into iOS too, so build that target before release.
- Before a release, decide whether the measured M5 result merits a UI codec
  option, add an automatic H.264 fallback for HEVC encoder creation failures,
  and test reconnect, mode changes, fullscreen presentation, and older peers.
  Keep this opt-in until those checks pass.
