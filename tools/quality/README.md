# Picture quality suite

Tools for measuring sharpness, colour and frame rate end to end: from the sender's virtual display, through the encoder and the network, to what the receiver decodes. They produced [research/hevc-m5-2026-09-29](../../research/hevc-m5-2026-09-29/README.md) and [research/sharpness-comparison-2026-09-29](../../research/sharpness-comparison-2026-09-29/README.md).

## What you need

- **A sender:** the Debug sender (`./run.sh`) streaming in Extend mode to exactly one receiver.
- **A receiving Mac:** the Debug receiver (`OpenDisplay Receiver Dev.app`), reachable over ssh (default host `imac`; set `OD_RECEIVER_HOST`). For captures, start it with the frame probe on:
  ```sh
  defaults write com.peetzweg.opensidecar.mac.receiver.debug dumpIdleFrames -bool YES
  ```
  Turn the probe off for frame-rate runs, since it decodes every frame a second time.
- Python 3 with `numpy` and `Pillow` on the sender.
- Output goes to `build/quality` (set `OD_QUALITY_DIR` to change it).

Run `tools/quality/build.sh` once. It compiles the test page and the benchmark here and the receiver tools on the receiving Mac.

## Tools

| Tool | What it does |
|---|---|
| `testpage.swift` | A 1600x900 pt window on the OpenDisplay screen, with small system and monospaced text, coloured text on coloured backgrounds, 24 solid patches, gradients, and 1 px lines and checkerboards. It writes its own ground truth at 2x and 2.5x, plus its position in stream pixels. Modes: `static`, `change` (blank, then the page all at once), and `scroll` (240 pt/s). All content is synthetic, so captures never include anything from your desktop. |
| `capture.sh <label>` | Shows the static page and saves the receiver's settled decoded frame. |
| `seq.sh <label> change\|scroll <N>` | Saves the next N decoded frames, to measure the first frame after a change or quality in motion. |
| `score.py <capdir> [--panel]` | Luma and chroma PSNR per region, plus ΔE of the patch centres. `--panel` first upscales the frame bilinearly to 5120 wide, as the receiver's layer does, and scores against a native render at that scale. |
| `score_seq.py <capdir> [--scroll]` | Per-frame scores for a sequence. Scroll frames are aligned automatically. |
| `crops.py <quality dir> <out dir>` | 3x zoomed side-by-side crops of the page only; safe to publish. |
| `measure.sh <label>` | Runs `motion.swift` (moving bars at 60 Hz) for 35 s, then averages the sender's stats: fps, median encode time, latency p50/p95, and dropped frames. |
| `mode.swift` (on the receiver, `/tmp/od-mode`) | Lists the receiving Mac's Retina modes, or switches to one, e.g. `od-mode 2560x1440`. |
| `decbench.swift` | `decbench encode hevc\|h264 <file> <png...>` on the sender, then `od-decbench decode <file>` on the receiver: the receiver's hardware decode throughput. |

## Debug switches used with the suite

These live in Debug builds only.
- **Sender** (`com.peetzweg.opensidecar.mac.debug`):
  - `bitrate` (Mbps)
  - `maxPendingEncodes` (encodes in flight)
  - `quality` (`best`/`balanced`/`fast`)
  - `failHEVCEncoder` and `failHEVCSession` (exercise the H.264 fallbacks)
  - `canvasAtStreamSize NO` (the old panel-sized canvas)
- **iOS receiver:** `-forceHEVCOffer YES` (HEVC in the simulator).

## Example

```sh
tools/quality/build.sh
tools/quality/capture.sh hevc-default && python3 tools/quality/score.py build/quality/cap/hevc-default --panel
tools/quality/seq.sh hevc-change change 40 && python3 tools/quality/score_seq.py build/quality/cap/hevc-change
ssh imac 'defaults write com.peetzweg.opensidecar.mac.receiver.debug dumpIdleFrames -bool NO'   # then restart it
tools/quality/measure.sh hevc-default
```

Keep only `crops.py` output in published research. Full frames (`recv.png`, `od-seq-*.png`) can show the rest of the virtual desktop.
