# Roadmap

This roadmap is for the OpenDisplay Mac/Android CN fork. It is intentionally
practical: keep the current working path stable, then improve polish and
maintainability.

## Priority 1: Stabilize The Android Receiver

- Improve connection state recovery after WiFi changes.
- Add clearer Android-side error states for decoder failures and network loss.
- Add more protocol self-tests around malformed frames and reconnect behavior.
- Validate touch and scroll behavior across more Android tablets.
- Track per-device decoder quirks when users report them.

## Priority 2: Make The Fork Easier To Use

- Keep Mac, iOS, and Android copy consistent in Chinese.
- Keep a Dock-visible Mac workflow for users who do not rely on menu bar icons.
- Add release packaging guidance when signing and notarization are available.
- Improve local diagnostics for permissions, local network discovery, and
  receiver reachability.

## Priority 3: Prepare Upstreamable Changes

- Split Android protocol additions into small, documented changes.
- Keep Mac sender changes compatible with iOS receivers.
- Separate localization-only changes from behavior changes where possible.
- Use focused pull requests if contributing pieces back to upstream.

## Priority 4: Future Capabilities

- Encrypted WiFi pairing.
- HEVC option for better quality per bit on supported devices.
- More complete gesture mapping.
- Android USB transport investigation.
- Better display-profile negotiation.
- User-facing package builds for non-developers.

## Non-goals For Now

- App Store or Play Store release.
- Remote desktop over the internet.
- Audio forwarding.
- Closed-source commercial packaging.
