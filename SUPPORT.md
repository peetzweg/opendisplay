# Support

This fork is source-first and community-maintained. The fastest way to debug a
problem is to include enough context to reproduce the connection path.

## Before Reporting

Check these first:

- Mac Screen Recording permission is granted.
- Mac Accessibility permission is granted if touch or scroll input is needed.
- Local Network permission is granted on devices using WiFi discovery.
- Mac and receiver are on the same local network for WiFi mode.
- VPN TUN mode is disabled or tested both on and off.
- The receiver app is open in the foreground.

## Useful Information

Please include:

- Mac model and macOS version
- Xcode version if building locally
- receiver platform: iOS/iPadOS or Android
- receiver device model and OS version
- mirror or extend mode
- USB or WiFi
- selected quality profile
- whether the problem is discovery, connection, video, cursor, input, latency,
  or app crash
- steps that reproduce the issue
- any log output or crash text

## Android-Specific Notes

Android devices vary in decoder, touch, and networking behavior. For Android
issues, also include:

- tablet brand and model
- Android version
- whether wireless debugging or USB debugging was used
- whether the app exits, freezes, shows black video, or keeps running without
  frames
- whether cursor and touch behave differently in mirror versus extend mode

## Expected Limits

- WiFi latency depends heavily on router quality, signal strength, multicast
  behavior, and VPN/network filters.
- Static screens may make capture and frame-rate metrics look lower because the
  sender has fewer changing frames to encode.
- Free Apple ID device installs can expire for iOS builds.
- Unsigned or locally signed Mac builds may need manual Gatekeeper approval on
  another Mac.
