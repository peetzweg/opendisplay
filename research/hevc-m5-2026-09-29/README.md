# HEVC vs H.264 on an M5 Pro sender, 2026-09-29

Sender: MacBook Pro (M5 Pro). Receiver: 2017 5K iMac (iMac18,3, Radeon Pro 570, macOS 13) over a Thunderbolt Bridge. Build: `feat/hevc-5k-mac-receiver` rebased onto main after PR 323 (canvas capped at the stream size); the measurements below used its opt-in flag, which the final branch replaces with automatic selection. Tracking: https://github.com/peetzweg/opendisplay/issues/10 and https://github.com/peetzweg/opendisplay/issues/322

All images are crops of a synthetic test page (`tools/testpage.swift`); no desktop content.

## Method

- **Test page**: 1600x900 pt window on the virtual display with system and monospaced text from 8 to 15 pt, coloured text on coloured backgrounds, 24 solid patches, gradients, and 1 px lines and checkerboards. The page renders its own ground truth at 2x and 2.5x.
- **Frames**: the Debug receiver probe (`Shared/IdleFrameDumper.swift`) decodes each received frame on a side session. It saves the settled frame, or the next N frames (`echo N > /tmp/od-dump-request`).
- **Scores** (`tools/score.py`, `tools/score_seq.py`): PSNR of luma (Y) and chroma (CbCr) per region, plus the CIE76 ΔE of patch centres. "Panel" scores first upscale the stream bilinearly to 5120, as the receiver's layer does (measured equal to bilinear in the 2026-09-29 sharpness study). They then compare against the page rendered natively at that scale.
- **Motion** (`tools/hevc-motion-test.swift` via `tools/measure.sh`): moving bars at 60 Hz, averaged over 5 sender stats windows. The receiver probe is off during fps runs.
- **Resolution switching**: the iMac's display mode was switched over ssh with `tools/mode.swift`.
- The scripts use this session's scratchpad paths; adjust `S=` before reuse.

## Frame rate (moving window, receiver fullscreen)

| Stream | Codec | Frames in flight | fps | Median encode | e2e p50 / p95 |
|---|---|---:|---:|---:|---:|
| 4096x2304 | H.264 | 1 (default) | 30 | 17 ms | 18 / 19 ms |
| 4096x2304 | H.264 | 2 | 42 | 17 ms | 19 / 36 ms |
| 4096x2304 | H.264 | 3 | 46 | 17 ms | 29 / 52 ms |
| 4096x2304 | HEVC | 1 | 30 | 18 ms | 20 / 20 ms |
| 4096x2304 | HEVC | 2 | 40 | 18 ms | 20 / 38 ms |
| 4096x2304 | HEVC | 3 | 45 | 18 ms | 37 / 56 ms |
| 5120x2880 | HEVC | 1 | 29 | 28 ms | 30 / 31 ms |
| 5120x2880 | HEVC | 2 | 29–30 | 27 ms | 49–55 / 57 ms |
| 5120x2880 | HEVC | 3 | 35 | 27 ms | 55 / 84 ms |

- **At the same raster the two codecs perform the same.** HEVC's higher rate in the handoff came from its two-frame pipeline, and H.264 with two frames in flight gains the same.
- **One frame in flight quantises to 30 fps.** An encode just over 16.7 ms misses every other 60 Hz capture.
- **The encoder engine tops out around 400–500 Mpx/s for either codec.** 5K60 needs about 885 Mpx/s, so the M5 Pro cannot do it with HEVC.
- **Pipelining at 5K doesn't pay.** Two frames in flight add ~25 ms of latency and no frames; one is the better setting there.
- **Receiver load is negligible.** The iMac's hardware HEVC decoder sat at about 1% CPU at 5K; the network had 0 drops.
- **Compared with the M1 Pro** (Sept 19 handoff): 5K HEVC went from ~23 to ~29 fps.

The shipped policy keeps one encode in flight for both codecs, as H.264 always had.

## Receiver decode headroom (2017 iMac, hardware decoder)

`tools/decbench.swift` hardware-encodes a clip on the sender, then decodes it on the iMac as fast as possible. The stress clip changes the whole screen on every frame at the 18 Mbps cap (about 40 KB per frame).

| Clip | One frame at a time | Pipelined |
|---|---:|---:|
| H.264 4096x2304, scrolling | 176 fps | 195 fps |
| H.264 4096x2304, full change every frame | 180 fps | 198 fps |
| HEVC 4096x2304, scrolling | 193 fps | 231 fps |
| HEVC 5120x2880, scrolling | 136 fps | 151 fps |
| HEVC 5120x2880, full change every frame | 135 fps | 140 fps |

5K HEVC decodes at more than twice 60 fps on the oldest Mac tested, so the Mac receiver's 5120x2880@60 offer is safe there. Older Intel Macs whose hardware also reports HEVC decode (Skylake, 2015–2016) were not measured.

## Sharpness and colour (settled frames, 18 Mbps)

| Case | Text Y | Colour text Y / CbCr | Patches ΔE mean / max |
|---|---:|---:|---:|
| H.264 4096 stream, 1:1 | 53.1 dB | 47.9 / 33.6 dB | 0.36 / 1.09 |
| HEVC 4096 stream, 1:1 | 53.9 dB | 47.6 / 33.7 dB | 0.36 / 1.09 |
| HEVC 5120 at Default, panel (1:1) | 54.0 dB | 47.6 / 33.7 dB | 0.36 / 1.09 |
| H.264 at Default, panel (4096 stretched to 5120) | 27.1 dB | 32.5 / 32.1 dB | 0.36 / 1.09 |

- **Settled frames at the same raster are equal.** Both codecs reach the 4:2:0 ceiling.
- **Colour is identical.** Coloured-text chroma is about 33.6 dB either way and flat-patch colour error is identical, so HEVC does not improve colour. Colour edges need 4:4:4 (ProRes 4444 or lossless tiles, #322).
- **Default is where the codecs split.** HEVC removes the 1.25x stretch. The 27 dB figure is mostly that non-integer stretch, which H.264 cannot avoid at 5K (see `2-default-panel-*`).

## After a change and while scrolling

Luma of the text region; "first frame" is the first decoded frame after the whole page appears at once.

| Case | H.264 | HEVC |
|---|---:|---:|
| First frame after change, 18 Mbps | 49.4 dB | 53.0 dB |
| Frame 3 after change, 18 Mbps | 53.0 dB | 53.6 dB |
| Scrolling 240 pt/s, 18 Mbps | 53.5 dB | 54.2 dB |
| First frame after change, 6 Mbps | 49.4 dB | 53.0 dB |
| Settled, 6 Mbps | 52.1 dB | 53.9 dB |
| Scrolling 240 pt/s, 6 Mbps | 48.7 dB | 54.1 dB |

- **HEVC removes the brief blur after a window switch.** H.264 needs about 3 frames to match HEVC's first frame.
- **On a constrained link, HEVC holds quality in motion.** At 6 Mbps (Wi-Fi-like) it is 5 dB better while scrolling, about equal to H.264 at 18 Mbps.

## More Space

- **HEVC**: the receiver advertises at most 5120x2880, so 2880x1620 and 3200x1800 give the same 5120 canvas as Default (`canvas capped at the stream size: 5120x2880 for a 6400x3600 panel`).
- **H.264**: More Space caps at 4096x2304, as at Default.

In both cases More Space adds no room over Default, and it costs nothing either.

## Images

| File | What it shows |
|---|---|
| `1-change-first-frame-{text,colour}-3x.png` | Reference, then H.264, then HEVC: first frame after a full-page change, 4096 stream, 18 Mbps |
| `2-default-panel-{text,colour}-3x.png` | iMac at Default, as the panel shows it: H.264 (4096 stretched, 2048x1152 pt desktop) vs HEVC (5120 1:1, 2560x1440 pt desktop). Text is physically smaller in the HEVC tile because the desktop is larger. |
| `3-scroll-6mbps-{text,colour}-3x.png` | Reference, then H.264, then HEVC while scrolling at 6 Mbps |

## Selection and compatibility checks (final branch, live)

| Case | Result |
|---|---|
| New sender, new iMac receiver at Default | HEVC 5120x2880 chosen automatically, no flags |
| HEVC encoder unavailable at the stream size (Debug `-failHEVCEncoder`) | H.264 canvas and stream from the start, 4096x2304 captured 1:1 |
| HEVC session fails after the canvas was sized (Debug `-failHEVCSession`) | H.264 at once, canvas rebuilt to 4096x2304 within ~0.5 s |
| New sender, release receiver 1.22.0 (H.264 only) | H.264 4096x2304, 1:1, as before |
| Sender from main, new receiver | H.264 4096x2304, receiver unaffected by its HEVC offer |
| iMac switched live: 2048x1152, 3200x1800, 1600x900, Default | HEVC 4096, 5120, 3200, 5120; every switch rebuilt the decoder, 0 decode errors |
| Mirror mode (MacBook Pro 3024x1964 display) | HEVC 3024x1964 1:1 |
| iPad Pro 13" simulator | H.264 (no hardware HEVC in the simulator); with Debug `-forceHEVCOffer YES`, HEVC 2064x2752 decoded and displayed |

Not yet tested on hardware: iPhone and iPad receivers, Intel senders (they stay on H.264 by design), and a reconnect over WiFi onto a different receiver build at the same address (covered in code: the sender holds HEVC until the new hello offers it).
