# Hardware keyboard and trackpad preview

English | [简体中文](HARDWARE_INPUT.zh-Hans.md)

This local implementation addresses the iPad Magic Keyboard use case tracked
by upstream [#6](https://github.com/peetzweg/opendisplay/issues/6). It is based
on `main` at `2e74ced51924bbda14a4d897a8459b710b37a7d9`.

Existing community work includes [#247](https://github.com/peetzweg/opendisplay/pull/247)
by kdbhalala and [#251](https://github.com/peetzweg/opendisplay/pull/251) by
Portgas443. This preview is a separate implementation of physical keyboard and
pointer forwarding; it is not a claim that those authors' contributions are
ours. Coordinate with those PRs before proposing another upstream PR.

## Behavior

- The iPad captures delivered hardware `UIPress` down/up events on the video
  view, including Command, Option, Control and Shift. Only supported HID
  Keyboard/Keypad usages are consumed; other press events remain local.
- macOS maps physical HID usages to virtual keycodes. Its selected layout and
  input method determine text. iPad-composed Unicode is not injected.
- macOS owns key repeat, using its configured repeat delay and interval.
- Trackpad motion uses public GCMouse raw deltas and UIViewController pointer lock
  on pv 5 peers, so the Mac cursor can cross monitors. GCMouse owns motion/buttons
  while UIKit exclusively owns scrolling. Finger and Pencil paths stay intact.
- The iPad settings offer a keyboard/trackpad toggle. Input is enabled only
  while the video view is visible, the app is active, and no settings,
  onboarding or update sheet owns focus.
- Losing focus, cancellation, backgrounding, disconnect, transport redial,
  display change and capture stop release owned keys/buttons. Reset is
  idempotent and does not release unrelated keys that this session did not own.
- No typed characters, key sequences, or clipboard contents are logged.

## Compatibility

The optional input extension uses proposed wire protocols 4 (keys/absolute pointer), 5 (relative pointer) and 6 (desktop-point scrolling). The minimum peer
version remains 1. A new iPad waits for a sender advertising protocol 4 before
sending new input types. Legacy video, touch, scroll and Pencil behavior is
preserved; no update gate or minimum version is raised.

Both ends must contain the new implementation to enable keyboard and full
trackpad forwarding. Changing only the Mac app cannot add capture code to the
App Store iPad receiver.

## Limits requiring physical-device verification

`Command-Tab`, Home/Globe actions, media keys and other iPadOS-reserved shortcuts
may never reach an app. This preview does not bypass system interception.
The supported cases, Chinese input through the Mac IME, focus transitions,
repeat timing, right-click and scroll direction must be tested with an actual
iPad Magic Keyboard. Compilation and mock-event unit tests do not establish
that these interactions work on a real device.

An unsigned build cannot be installed on an iPad. Local deployment needs a
development team/certificate/profile in Xcode, a unique development bundle ID,
and Developer Mode on the iPad. Use a separate development app so the App Store
installation remains recoverable. Do not embed credentials in this source.

## Validation commands

```sh
DEVELOPMENT_TEAM='' xcodegen generate
xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac \
  -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' \
  MARKETING_VERSION=1.22.0 CURRENT_PROJECT_VERSION=1220014 \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' test
xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecariOS \
  -configuration Debug -derivedDataPath build-ios \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The unit tests replace the CGEvent posting sink, so they inspect event types,
keycodes, modifier flags, pointer ownership and cleanup without typing into
the user's apps. See the separate validation receipt for the actual outcomes.

## Device acceptance

1. Verify old Mac/new iPad and new Mac/old iPad still stream and accept touch.
2. Pair two new builds. Open a Mac text editor on the captured display.
3. Type letters/numbers; test Return, Backspace, Tab and all arrow keys.
4. Test Shift selection, Command-A/C/V/Z, Option-arrow and Control combinations.
5. Select a Chinese input method on the Mac and verify composition/candidates.
6. Hold a letter and arrow; release them; confirm repeat stops promptly.
7. Move the pointer, click, drag, double-click, right-click and scroll both axes.
8. Open iPad settings, change app, lock/unlock, unplug/replug, rotate, and stop
   capture on the Mac while keys/buttons are held. No modifier/drag may stick.

## References

- [Handling physical keyboard presses](https://developer.apple.com/documentation/uikit/handling-key-presses-made-on-a-physical-keyboard)
- [Trackpad and mouse input](https://developer.apple.com/videos/play/wwdc2020/10094/)
- [Pan recognizer scroll types](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask)

The source retains upstream GPL-3.0 licensing and attribution.


## Localization

New input controls use `Shared/InputStrings.xcstrings` (English and zh-Hans).
This is a scoped contribution toward #269, not full product localization.

## Optional physical Command/Option swap

An opt-in setting swaps left/right Command and Option usages and modifier snapshots consistently across keyboard, pointer, drag and scroll events. It defaults off; switching it releases old held state first. While on, use Option-Tab / Option-Space for Mac app switching / search and Option-C/V for Mac copy/paste. Original Command-Tab / Command-Space remain iPadOS shortcuts. This is an alternative mapping, not a system keyboard grab.

## Foreground and reconnect readiness

The UIKit view directly observes connection, negotiated protocol and video readiness, including a welcome that arrives after view construction. Scene changes preserve the receiver's root identity. Activation/key-window transitions retry focus and pointer lock briefly; mouse rebinding happens at the first eligible attempt. Background/modal/key-window guards prevent focus stealing and stale attempts are cancelled on input release.

The combined local preview passed two real-device switch-away/back cycles without termination or window resizing; both restored first responder, raw mouse and pointer lock. The user subsequently confirmed the other input/localization issues were resolved. Platform-reserved physical shortcuts are still explicitly excluded.
