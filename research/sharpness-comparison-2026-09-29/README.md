# Sharpness comparison, 2026-09-29

Sender: MacBook Pro (M5 Pro). Receiver: 2017 5K iMac (iMac18,3, macOS 13) over a Thunderbolt Bridge (~15 Gbit/s TCP). Content: a terminal window with small text, captured after it stopped changing. Tracking issue: https://github.com/peetzweg/opendisplay/issues/322

## Images

| File | What it shows |
|---|---|
| `2-sharp-vs-opendisplay-zoom3x.png` | Sharp (top) vs OpenDisplay at the iMac default before the fix (bottom), panel pixels, 3x zoom |
| `3-opendisplay-imac-default-vs-lowered-zoom3x.png` | OpenDisplay with the iMac at its default setting (top) vs lowered to "looks like 2048x1152" (bottom), stream pixels, 3x zoom |
| `6-sharp-vs-opendisplay-lowered-zoom3x.png` | Sharp (top) vs OpenDisplay with the iMac lowered (bottom), panel scale, 3x zoom |
| `7-canvas-fix-before-lowered-after-zoom3x.png` | Canvas fix check, stream pixels, 3x: before the fix at the iMac default, iMac lowered, and with the fix at the iMac default |

Only these zoomed crops are kept; full frames and 1:1 captures stay local.

## How each frame was captured

- **Sharp**: a patched build (Retina virtual display, 3840x2160 stream, Thunderbolt Bridge support) whose receiver reads back its own OpenGL framebuffer after the lossless tiles are drawn. This is exactly what the panel showed, at 5120x2880.
- **OpenDisplay**: a Debug-only receiver probe (`Shared/IdleFrameDumper.swift`) that decodes each received frame on a side session and saves one on request. This is the decoded stream at 4096x2304, *before* any scaling onto the panel. For images 2 and 6 it was upscaled to 5120 with `sips` to approximate the panel.
- Screen capture over ssh on the iMac only returns the wallpaper (no Screen Recording permission), hence the in-app readbacks.

## Findings

1. **Sharp**: pixel-exact (no compression haze), but its 3840-wide frame is stretched 1.33x onto the 5120 panel without smoothing, so strokes are uneven (1 vs 2 px wide). Stock Sharp is non-Retina (`hiDPI = 0`, 2560x1440 at 1x), which looks worse still.
2. **OpenDisplay at the iMac's default setting blurs twice**: the iMac reports 5120x2880, so the sender creates a 5K virtual display, then captures it downscaled to 4096x2304 (the H.264 limit) before encoding, and the receiver scales it back up to 5120. Log: `stream selected: H.264 4096x2304 @55fps from 5120x2880`.
3. **With the iMac lowered to 2048x1152**, the virtual display is 4096x2304, the capture is 1:1 (`from 4096x2304`), and text is clearly crisper at the same 18 Mbps.

4. **Canvas fix verified** (branch `fix/canvas-at-stream-size`): at the iMac's default setting the sender now logs `canvas capped at the stream size: 4096x2304 for a 5120x2880 panel` and captures 1:1. Image 7 shows the fixed default matching the lowered setting in the stream. What these captures cannot show is the last step: with the fix, our receiver scales 4096 to the 5120 panel; with the iMac lowered, macOS scales it as a display mode. Any remaining difference on the panel comes from that step.

5. **The receiver's scaler is not the problem.** A test app on the iMac showed a known 4096 page in an `AVSampleBufferDisplayLayer` exactly like the Mac receiver (4:2:0, aspect fit) and read back its own window at 5120x2880. Scored against the same page rendered natively at 5120, it matched offline bilinear exactly (22.53 dB); nearest 19.94, Catmull-Rom 22.53, Mitchell 22.60, Lanczos 22.51. The upscale itself is the limit, so a fancier filter would not help measurably.
6. **Colour tagging.** Tagging a frame with the BT.709 transfer function makes the layer lift shadows (dark grey 41 becomes 56). Our live stream carries no colour tags at all (receiver log: `primaries=- transfer=- matrix=-`), so it is not affected. Untagged colour is about 1.4 dB less accurate than sRGB-tagged on the coloured page, so explicit sRGB/BT.709 tagging on the sender is a follow-up worth measuring across iPhone, iPad and Mac receivers.

## Fix direction

When the stream must be capped below the panel size, create the virtual display at the capped size, so capture is always 1:1 and there is only one scaling step (on the receiver). On a 5K iMac this gives "looks like 2048x1152" by default. Full 2560x1440 space at 1:1 needs a 5K stream (HEVC, ProRes or lossless tiles), see #322.
