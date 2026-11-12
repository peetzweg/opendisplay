# Verify the Mac receiver's notch-area mode

The opt-in mode uses the full primary panel, including the strip beside the camera, without entering a native fullscreen Space. The default remains native fullscreen. The camera itself still obscures pixels; this is extra desktop area, not notch avoidance.

## Automated preference checks

The hostless `NotchAreaPreferenceTests` check that the mode defaults off, persists enable/disable choices, and does not overwrite the separate native-fullscreen preference. They restore the test process's defaults; they do not change the installed receiver's settings.

To build and run only the hostless test bundle, without rebuilding or launching either app:

```sh
out=$(mktemp -d /tmp/opendisplay-notch-tests.XXXXXX)
xcodebuild -project OpenSidecar.xcodeproj -target OpenSidecarMacTests \
  -configuration Debug SYMROOT="$out/products" OBJROOT="$out/intermediates" build
xcrun xctest "$out/products/Debug/OpenSidecarMacTests.xctest"
```

These tests do not prove AppKit window placement or sender resizing. Use a real pair of Macs for those boundaries.

## Two-Mac acceptance check

Use a notched Mac as receiver. Keep the sender and receiver versions recorded with the results. Test with the receiver's primary display at its default Retina mode first. Do not change Screen Recording permissions during the run.

1. With “Use area around camera” off, connect and verify that the existing native-fullscreen behaviour and remembered green-button choice are unchanged.
2. Turn the option on while streaming. The video window should rebuild without a native fullscreen animation or a new Space. Check that the stream contains desktop pixels beside the camera, not a black unused strip.
3. Confirm in the logs that the receiver's announced panel includes the previous top inset and that the sender's new canvas follows it. Codec sizing can require an even pixel height; a two-pixel difference is not itself a notch inset. A full-panel window alone does not prove exact 1:1 video scaling.
4. Switch to another app. Its windows must be able to come forward; the receiver must not float above them. The normal menu bar and Dock should be available in the other app.
5. Return to the receiver. The video should cover the primary screen and hide the menu bar and Dock. This mode intentionally uses hard-hide, not Ghostty's reveal-at-edge auto-hide.
6. Press Esc. Only the video window should close; the stream should remain connected. Use “Show Window” to restore it.
7. Close the video window again and disconnect. Verify that the menu bar and Dock are restored.
8. Reopen the receiver and reconnect. The opt-in choice should persist. Turn it off and confirm the native-fullscreen preference still behaves as before.
9. Repeat with the option off on a non-notched receiver. Screen selection and external-monitor support are not added by this change; the existing primary-panel policy remains.

Record pass/fail and the actual window/stream dimensions for each case. A visual check cannot establish exact pixel mapping on a scaled display mode.

## Existing evidence and remaining limits

The combined personal fork was exercised on two Apple-silicon MacBook Pros, and the owner confirmed notch-strip coverage and ordinary app switching. The v1.30.2-based combined fork builds both Mac apps and passes 146 tests. The independent notch branch's hostless test bundle passes 149 tests, including the three preference checks. The independent branch has not yet repeated the full manual checklist above.

The implementation does not add screen-change handling, display selection, or a shared manager for application-wide presentation options. It assumes the existing single video-window owner. Those are review considerations, not claims of demonstrated failures.

Related background: [Mac receiver screen/notch questions (#257)](https://github.com/peetzweg/opendisplay/issues/257) and [accepted native-fullscreen behaviour (#300)](https://github.com/peetzweg/opendisplay/issues/300). Neither issue is reopened or claimed fixed by this optional alternative.
