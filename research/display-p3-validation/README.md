# Display P3 capture and encoding: reproducible API evidence

This standalone macOS probe captures its own explicitly Display P3 chart through ScreenCaptureKit, encodes it with VideoToolbox, reconstructs the video format from H.264/HEVC parameter sets, decodes it, and compares known patch interiors in Display P3. It compares unchanged capture-buffer labels against the three attachment replacements used by the colour patch.

It is API evidence, not an automated regression test of `MacSender`: it mirrors that code's settings rather than importing the app. It captures a window, not the app's virtual display or a mirrored physical panel. The app's actual wiring and the generated virtual-display profile still require separate checks.

## Run

Requires macOS 14.2 or newer, a logged-in graphical session, Xcode/Command Line Tools and Screen Recording permission for the launching terminal. The probe checks permission but never requests it or changes TCC settings. It shows a floating chart briefly and captures only that window; it does not write desktop screenshots or change installed app settings.

```sh
out=$(mktemp -d /tmp/opendisplay-p3-probe.XXXXXX)
xcrun swiftc research/display-p3-validation/main.swift -o "$out/p3-probe"
"$out/p3-probe" > "$out/nv12.jsonl"
"$out/p3-probe" --bgra > "$out/bgra.jsonl"
```

By default the capture is 1280×768, 8-bit video-range NV12 with the BT.709 YCbCr matrix. `--bgra` exercises the sender's debug capture-format alternative. Both use Display P3 primaries with the sRGB transfer curve. This is not HDR or 4:4:4 video.

Each run first encodes with the capture attachments unchanged, then repeats after setting primaries, transfer and matrix to match the requested capture space and encoder. It runs both codecs. The parameter-set reconstruction verifies that colour tags survive the boundary the normal receiver relies on; it does not test a real network transport or `AVSampleBufferDisplayLayer` presentation.

The decoded image's colour metadata is consumed by Core Image and converted to explicit Display P3 before comparison. The probe averages 9×9 pixels at each patch centre. It checks twelve greys and four colour patches, including wide-gamut content. It allows a maximum absolute RGB-channel error of six 8-bit levels in the sampled patch means for the candidate, accounting for YUV and codec rounding; this does not bound individual-pixel error and is not a perceptual colour-difference metric or a guarantee for arbitrary images. All patch values and observed attachment/format tags are emitted as JSON Lines.

Exit codes:

- `0`: both candidate codecs retain P3 D65 / sRGB / BT.709 tags after parameter-set reconstruction and all sampled patches are within tolerance.
- `1`: a numerical/tag check fails, an API call fails, or acquisition times out. Read stderr and the JSON records; an acquisition/API failure is not itself evidence of a colour defect.
- `77`: Screen Recording permission is unavailable; no capture was attempted. A skipped run is not a pass.

### Negative control

```sh
"$out/p3-probe" --omit-relabel > "$out/without-relabel.jsonl"
```

This treats the unchanged capture-buffer labels as the candidate. On the measured system it exits `1` on the actual wrong decoded values, not a synthetic assertion failure. The default candidate exits `0`. A future OS might change SCK's labels or pixel conversion; record that result rather than assuming the negative control must always fail. Do not use this probe to justify unconditional claims about every SCK version.

## Measured result

2026-11-12, M1 Pro (`MacBookPro18,1`), macOS 27.2.1 build 26B131, Xcode 27.2. Hardware H.264 and HEVC encoders were selected. Both codecs gave the same broad-patch results below. Raw JSON records are included alongside this document.

| Capture | Buffer labels before replacement | Grey 128 unchanged → replaced | Largest channel error unchanged → replaced |
|---|---|---|---|
| NV12 video range | BT.709 primaries, transfer, matrix | (139,140,139) → (128,128,128) | 88 → 2 |
| BGRA | All three tested labels absent | (128,128,128) → (128,128,128) | 87 → 1 |

For NV12, P3 green (60,180,75) decoded as (104,186,96) with the original attachments and (61,179,75) with replacement. Correct tags survived reconstruction for both codecs even in the wrong-pixel control: tags alone were insufficient. The measured conclusion is that relabelling this captured chart before encoding avoids the demonstrated conversion. It does not establish that every frame from every source/OS needs the same replacement.

The `--omit-relabel` run exited `1`; default and BGRA runs exited `0`. Build and capture happen independently of the production apps. No production app was rebuilt or installed for these measurements.

## Production-path verification before submission

Record exact sender/receiver versions and hardware for each run. Do not collapse a combined-fork field test into evidence that each standalone branch passed the same test.

- Verify that the actual virtual display's profile is Display P3, including its neutral tone response. Chromaticities alone do not prove the tone curve.
- On the actual sending Mac, run this probe as well as the installed sender. Compare an explicitly tagged chart on the virtual desktop with the normal receiver's displayed result on the same panel, preserving/converting image profiles before numerical comparison.
- Repeat Extend and Mirror, H.264 and HEVC, and video-range NV12. Keep BGRA as a diagnostic, not the only passing capture format.
- Check the normal Mac display-layer path and an iOS receiver. The optional iOS Metal shader has its own colour conversion; passing normal playback does not validate that shader. Android and Linux receivers must also be checked for how they interpret P3 primaries and the sRGB transfer tag.
- Include a non-P3 receiver and older supported OS/hardware where available. Let colour management map out-of-gamut content; do not assume identical raw RGB bytes across differently profiled panels.
- Use flat colour/grey patches and text/edge controls. Do not claim that colour metadata fixes 4:2:0 chroma loss, scaling or sharpening.
- On lock/unlock or a reconnect, record whether the pipeline changes. Receiver privacy blanking is separate work; this patch does not fix it.

Historical combined-fork evidence: the owner confirmed a substantial improvement on two XDR MacBook Pros. An actual two-Mac broad-grey comparison matched within 1/255 in early captures, but a later post-reconnect capture showed up to 12 levels of attenuation. The owner subsequently reported no visible difference and no remaining harshness. The cause of that transient result was not established. This is not evidence for a global gamma adjustment or universal pixel identity.

Related picture-quality background: [#313](https://github.com/peetzweg/opendisplay/issues/313) and [#322](https://github.com/peetzweg/opendisplay/issues/322). Their refinement/chroma work is distinct; this probe does not close either track.
