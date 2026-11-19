# Native (direct) touch on macOS 27 — feasibility spike

Goal: make touches on the receiver arrive on the Mac as **direct touches**
(`NSTouch.TouchType.direct`), the way macOS 27 Sidecar delivers them, instead of
being translated into mouse events that move the system cursor
(`Mac/InputInjector.swift`).

Host: MacBook Pro (Apple silicon, Touch Bar), macOS 27.0.1 (26A434), Xcode 27.1, SIP on.

## What macOS 27 offers

- [TN3212](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support.md):
  Sidecar on iPadOS 27 delivers direct touches. Apps receive them **only through
  gesture recognizers**, not the responder chain, `sendEvent(_:)` or event
  monitors. For apps that don't adopt them, AppKit emulates: tap → click, pan →
  trackpad scroll (with phases), long press → right click, pinch/rotate →
  trackpad magnify + rotate. That emulation is exactly the "touchscreen feel"
  OpenDisplay lacks today, and it comes for free if touches enter as direct touches.
- New public API: `NSScreen.touchCapabilities` (`.multiTouch`),
  `NSScrollView.isTouchScrollingEnabled`, `NSIsTouchNative` Info.plist key.
- Nothing public lets a third-party process *generate* direct touches.

## How Sidecar does it (static analysis)

- `/usr/libexec/SidecarDisplayAgent` contains a `SidecarHID` module with
  `TouchScreenDigitizer`, `TouchTracker`, `Multitouch`, strings
  `IOHIDUserDeviceCreate`, `MacOSCompatibleTouchReports`, `supportsNativeTouches`,
  and `Unable to configure displayUUID for %u`.
  → Sidecar creates a **virtual HID touchscreen digitizer** (IOHIDUserDevice) per
  Sidecar display and binds it to that display's UUID.
- Its entitlements include `com.apple.hid.manager.user-access-device`,
  `com.apple.private.hid.client.event-dispatch`, `com.apple.iohideventsystem.server`.
- WindowServer (SkyLight) hosts `BKHIDDirectTouchEventProcessor` (the iOS
  backboardd touch pipeline) and `handle_digitizer_added`, next to a
  `displayUUID` string; BackBoardHIDTouchEventProcessor references
  `DisplayIntegrated`, `SurfaceDimensions`, `touchScreen`,
  `SupportExternalTouchscreen`. Feature flags `WindowServer/DirectTouchEventType`
  and `ModernSidecarProcessor` are FeatureComplete.
  → Hypothesis: WindowServer turns any digitizer HID service that carries a
  `displayUUID` property into direct touches on that display. Not yet verified;
  `GetModernSidecarEventProcessorForAuditTokenFGOnly` hints at Sidecar-specific
  gating as well.

## Experiments

| # | Test | Result |
|---|---|---|
| 1 | `HIDVirtualDevice` (CoreHID) touchscreen, no entitlement | `init` returns nil |
| 2 | Same, `com.apple.developer.hid.virtual.device` ad hoc / Apple Development signed, no profile | killed at launch (SIGKILL, AMFI) |
| 3 | `kCGSEventDirectTouch` (37) CGEvent with digitizer IOHIDEvent attached (`SLEventSetIOHIDEvent`), posted to own pid and HID tap, no Accessibility | nothing reaches the gesture recognizer; HID-tap post dropped (`CGPreflightPostEventAccess=false`) |

`IOHIDUserDeviceCreateWithProperties` documents the same
`com.apple.developer.hid.virtual.device` requirement. That entitlement is a
managed capability ("HID Virtual Device") requested per App ID in the developer
portal; approval times reported by others vary (some pending for months).

Side finding: trackpad gesture CGEvents (type 29) carry the full digitizer
IOHIDEvent collection (hand + fingers), visible via `CGEventCopyIOHIDEvent`.

## Public-API touch mode (what shipped on `feat/touch-mode`)

While the entitlement is pending, the touch experience was rebuilt on public
APIs plus the long-standing gesture CGEvent fields:

- pointer handoff (touch hides the pointer, the mouse resumes where it was),
- long press / two-finger tap → right click, double tap → double click,
- scroll phases + momentum,
- pinch → magnify: NSEventTypeGesture (29) with field 110 = 8 (zoom),
  132 = IOHIDEventPhaseBits, 113 = magnification, posted at the HID tap (the
  fields Mac Mouse Fix and Hammerspoon use). Verified on macOS 27.0.1 with
  TouchProbe on the device display: 14 pinches arrived as 14 complete
  `NSMagnificationGestureRecognizer` began → ended sequences (cumulative
  magnification −1.75 … +2.01). Posting needs the Accessibility permission;
  a process without it (TouchProbe launched from a shell) cannot even post a
  plain scroll to its own pid.

## Tools

- `TouchProbe.swift` / `build.sh` — window that logs direct/indirect touches via
  a gesture recognizer, AppKit's mouse emulation, and a listen-only session
  event tap (with attached IOHIDEvents). `--inject` runs experiment 3.
  Log: `~/Library/Logs/TouchProbe.log`.
- `sidecar-dump.sh` — dumps virtual HID devices, digitizer `displayUUID`
  properties and display UUIDs into `results/` (not committed: the dumps are
  machine-specific). Run it once without Sidecar as a baseline.

## Pending

- Sidecar observation (iPad on iPadOS 27): registry properties of Sidecar's
  digitizer and what TouchProbe logs for a real direct touch.
- A virtual digitizer with Sidecar's properties, once the entitlement is
  available, to test whether WindowServer accepts non-Sidecar digitizers.
