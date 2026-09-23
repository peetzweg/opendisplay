# Mac receiver controls and audio forwarding

Research snapshot: 2026-09-22, against the current worktree.

## Short answer

- **Remote fullscreen:** viable and low-risk. The receiver already owns an
  AppKit video window that has native fullscreen enabled. Add an idempotent
  desired-state control message; it needs no special macOS permission.
- **Receiver Mac brightness:** not viable as a supported product feature.
  macOS does not expose a documented public API for an app to set the built-in
  panel backlight. External-display brightness is hardware-specific. Private
  APIs would be unsupported and conflict with App Review's public-API rule.
- **Sender system audio on the receiver Mac:** viable with public APIs. Capture
  audio using ScreenCaptureKit and play PCM through AVAudioEngine, but carry it
  over a separately negotiated, bounded-latency connection rather than the
  existing video TCP stream.

## Existing architecture

- The receiver listens; the sender dials one framed TCP connection. Video and
  control share it. The optional cursor UDP channel exists specifically to
  avoid video-induced head-of-line blocking. See
  [PROTOCOL.md](../PROTOCOL.md#1-roles-and-transport) and
  [the cursor side channel](../PROTOCOL.md#63-cursor-side-channel-udp).
- The Mac receiver creates an `NSWindow` for video, declares it a
  `fullScreenPrimary` window, and currently directs users to the green traffic
  light for fullscreen. See
  [MacReceiver.swift](../MacReceiver/MacReceiver.swift#L179-L199).
- The sender captures its virtual display with ScreenCaptureKit, encodes H.264,
  and sends frames on its serial video queue. See
  [MacSender.swift](../Mac/MacSender.swift#L847-L883) and
  [MacSender.swift](../Mac/MacSender.swift#L2197-L2218).

## Remote fullscreen

`NSWindow.toggleFullScreen(_:)` is the public AppKit mechanism for native
fullscreen and requires neither Screen Recording nor Accessibility permission.
The receiver's macOS 12 deployment floor supports it.

Do not send a remote `toggle` command: duplicate/replayed messages or a local
green-button change can otherwise invert the intended state. Add an additive
sender-to-receiver `presentation` message with a `fullscreen` Boolean desired
state. The receiver should reconcile the actual window state only when it
differs, retain a command received before the video window exists, and apply it
when streaming creates that window. Unknown control types already must be
ignored, so compatible older peers continue working.

Sources:

- [Apple: NSWindow.toggleFullScreen(_:)](https://developer.apple.com/documentation/appkit/nswindow/togglefullscreen(_:))
- [Apple: NSWindow.StyleMask.fullScreen](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullscreen)
- [OpenDisplay control-message evolution](../PROTOCOL.md#6-control-messages)

## Receiver brightness

Apple documents user-facing brightness controls in Displays settings and notes
that availability varies with display type; it does not provide a documented
AppKit, Core Graphics, or DisplayServices public API for an app to read or set
a Mac's built-in display backlight. Third-party approaches using private
DisplayServices, IOKit registry details, or synthetic brightness-key events are
not a stable product foundation and cannot meet the App Store guideline that
apps use public APIs.

External display brightness cannot be assumed: host control normally depends
on the display and connection exposing DDC/CI, which is outside the supported
Mac panel-control surface. A receiver feature must not claim to control every
attached display.

The appropriate tracking item is therefore a small feasibility spike with an
explicit exit condition: identify a public, App-Review-permitted solution on
the supported hardware, or close it as unsupported. It must not ship private
API linkage or a privileged workaround.

**Correction (2026-09-23):** the App Review framing above overstates the
actual constraint. OpenDisplay's Mac apps already ship outside the App Store
via Developer ID + notarization, and the sender already depends on a private
API (`CGVirtualDisplay`) for that exact reason — see README.md: "which is
precisely why this project can't ship on the App Store and lives on GitHub
instead." So avoiding App Review is not, by itself, a reason to exclude a
private-symbol brightness path on the Mac receiver. The real question for
#301 is whether the team wants to accept the risk of an undocumented,
version-fragile symbol (no Apple support path, can silently break on a future
macOS release) for this specific feature, independent of App Store rules. See
external validation below for what that risk looks like in practice.

Sources:

- [Apple Support: Change your Mac display's brightness](https://support.apple.com/guide/mac-help/change-your-displays-brightness-mchlp2704/mac)
- [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple: App Review Guidelines 2.4.5 and 2.5.1](https://developer.apple.com/app-store/review/guidelines/)

## System-audio forwarding

The sender can set `SCStreamConfiguration.capturesAudio`, attach an `.audio`
output, and receive audio `CMSampleBuffer` values containing an
`AudioBufferList`. Start with 48 kHz stereo, the documented default. This
captures system audio, not microphone input; microphone capture is a separate
macOS 15+ capability and should remain out of scope. Set
`excludesCurrentProcessAudio` unless the sender deliberately needs its own
process audio included.

On the receiver, `AVAudioEngine` and `AVAudioPlayerNode.scheduleBuffer` can
play decoded PCM through the selected macOS output device without capture
permissions. The receiver still follows normal macOS output-device, volume, and
mute behavior.

Use a separate receiver-listened TCP connection, advertised additively in
`hello` alongside a fresh session token. Sending audio as an existing video
frame is incompatible with the pv 3 JSON/H.264 demux. Sharing a future typed
video connection would also let large video writes delay real-time audio.

For the first slice, send fixed blocks of S16LE PCM with a sequence number,
sample count, and capture timestamp. PCM costs about 1.536 Mbit/s at 48 kHz
stereo, needs no codec delay, and is insignificant on the intended LAN/direct
cable paths. Maintain a 40-80 ms bounded jitter queue, dropping/resetting
stale audio rather than accumulating latency. Measure queue depth, underruns,
dropped/late blocks, capture-to-send time, and estimated A/V offset. A later
A/V-synchronization iteration can act on those measurements.

System-audio capture is system-wide, not intrinsically scoped to the virtual
display, so the user-facing promise must be "stream this Mac's system audio".
Protected content remains subject to macOS capture policy.

Sources:

- [Apple: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [Apple: SCStreamConfiguration.capturesAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
- [Apple: SCStreamOutputType.audio](https://developer.apple.com/documentation/screencapturekit/scstreamoutputtype/audio)
- [Apple: SCStreamConfiguration.sampleRate](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate)
- [Apple: SCStreamConfiguration.channelCount](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/channelcount)
- [Apple: SCStreamConfiguration.excludesCurrentProcessAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio)
- [Apple: AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Apple: AVAudioPlayerNode.scheduleBuffer](https://developer.apple.com/documentation/avfaudio/avaudioplayernode/schedulebuffer(_:at:options:completionhandler:))

## External validation (2026-09-23)

Cross-checked the conclusions above against two comparable products: targetBridge
(local sibling repo at `../targetBridge`, open source, Mac-to-Mac sender/receiver
reviving Target Display Mode) and RetinaRelay (retinarelay.com, commercial,
also Mac-to-Mac). Both are Mac-to-Mac, not tablet receivers, so treat this as
protocol/technique inspiration rather than a like-for-like receiver comparison.

**Brightness — shows what the private-symbol path actually costs, doesn't
settle whether OpenDisplay should take it.**
Note the correction above: since OpenDisplay's Mac apps already ship outside
the App Store via notarized Developer ID distribution (and the sender already
uses the private `CGVirtualDisplay` API for that reason), App Review is not
the deciding factor for #301 the way earlier framing assumed. What these two
products show instead is the real tradeoff. targetBridge's receiver sets
panel brightness by `dlopen`-ing
`/System/Library/PrivateFrameworks/DisplayServices.framework` and calling the
private `DisplayServicesSetBrightness(CGDirectDisplayID, float)` symbol (the
same private symbol Lunar and similar menu-bar tools use) —
`TargetBridge-Receiver/TBReceiverC/src/display.c:1490-1520`, driven by a
`brightness` control message defined in
`TargetBridge-Receiver/TBReceiverC/src/proto.h:29,55` and sent from
`TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift:999-1002,1696-1702`.
Notably, targetBridge itself is ad hoc-signed (not even notarized) via GitHub
Releases zips, one step below OpenDisplay's own notarized distribution — so it
isn't evidence that notarized private-symbol use is unsafe, only that this
particular symbol is undocumented and unsupported by Apple regardless of
distribution channel. RetinaRelay, which is Developer-ID-distributed like
OpenDisplay, goes the other way and disclaims the feature outright: its FAQ
states "the app only decodes and displays video, and has no brightness,
backlight, or HDR controls of any kind." So even a product on our exact
distribution model chose not to touch it. Neither data point proves the
private-symbol path is unsafe for OpenDisplay specifically, but neither shows
a maintained public-API alternative either — #301 should record this as a
version-fragility/support-risk decision, not an App Review one.

**Audio — confirms the ScreenCaptureKit + separate-channel approach, adds real
production lessons.**
targetBridge sends `capturesAudio = true` with `excludesCurrentProcessAudio =
true` on an `SCStream` (`TBDisplaySenderService.swift:2318-2319`) — matching
this doc's approach — and documents that they had to migrate their extended-
desktop capture path from the legacy `CGDisplayStream` to `SCStream`
specifically to unlock audio capture in that mode (`docs/audio.md`). Worth
checking whether OpenDisplay's own extended/virtual-display capture already
uses `SCStream` before audio work starts, since the same constraint will apply.
On playback, they document that `SDL_QueueAudio` (a push/queue API) produced
creeping latency for three distinct reasons: the OS output buffer hides true
backlog size, TCP bursts after congestion arrive in clumps, and a busy-spun
audio thread starves without a `SDL_Delay(1)` when idle. Their fix was a
pull-based audio callback backed by a ring buffer with a bounded latency
ceiling (150 ms / 28,800 bytes) that trims the *oldest* buffered bytes when
exceeded, rather than a hard flush — avoiding both creeping delay and audible
pops. This is directly reusable guidance for the `AVAudioEngine`/
`AVAudioPlayerNode` receiver playback path this doc already proposes; the
40-80 ms bounded jitter queue above should use a trim-oldest resync rather
than a flush-on-overflow one. They also key mute per receiver session
(`docs/audio.md §4`), matching this doc's per-connection framing.
RetinaRelay takes a different architecture worth noting as an alternative:
rather than an app-internal audio pipeline, it "installs a real audio device
rather than eavesdropping on your existing one" — i.e. the receiver Mac gains
an actual selectable macOS output device, hooked to native volume
keys/mute, with playback timed to track "the same measured delay the video
does." That is a heavier lift (a CoreAudio driver/device, install-time admin
prompt) but gives a more native UX than in-app volume control; worth a mention
next to the ScreenCaptureKit approach if the audio work ever gets a design
review, but not a reason to change the recommended v1 slice.

Sources: local read of `/Users/mnml/git/targetBridge` (see file:line citations
above); https://www.retinarelay.com/ (home, /faq, /compatibility, /changelog).

## Security note

The current protocol intentionally has neither TLS nor authentication and is
for trusted local networks. Fullscreen has a modest impact, but receiver
controls are still actions an unauthenticated LAN peer can request. The audio
channel's session token prevents a second local connection from attaching to
the wrong active stream; it does not authenticate the peer. Pairing/authentication
should be tracked separately before adding higher-impact receiver actions.

Source: [OpenDisplay transport security model](../PROTOCOL.md#1-roles-and-transport).
