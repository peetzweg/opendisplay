# od-receiver: OpenDisplay receiver for Windows

A native Windows receiver for the [OpenDisplay](https://github.com/peetzweg/opendisplay)
wire protocol (`pv` 3). A Mac running OpenDisplay.app can use it to extend its desktop
onto a Windows PC's screen. It is built for the lowest possible end-to-end latency.

## Notice

Written from the protocol specification ([PROTOCOL.md](../PROTOCOL.md) and
[COMPATIBILITY.md](../COMPATIBILITY.md)), not ported from the other apps in this repository.
Licensed GPL-3.0-only, like the rest of the repository. Rust on Win32/D3D11/Media Foundation;
it shares no code with the `linux/` workspace.

## Status

| Milestone | State |
|---|---|
| 1. Framing, demux, control messages | done |
| 2. TCP listener, mDNS, hello/ping/pong, fake sender | done |
| 3. Media Foundation zero-copy H.264 decode | done |
| 4. DXGI flip-model presentation | done |
| 5. Cursor overlay and UDP side channel | done |
| 6. Input | done |
| 7. Stats, overlay, config, tray | done |

## Build

```
cargo test
cargo run --bin od-receiver
```

The per-install id is stored in `%LOCALAPPDATA%\od-receiver\id`.

The receiver opens a borderless window covering the configured monitor and puts an icon in the
notification area. While no video is on screen, it shows an idle screen titled "Open Display
receiver". The status line reads "Waiting for a sender to connect", or "Connected to <ip>,
starting video…" once a sender connects. Below it are three steps that name this PC as it
appears in the sender. When the sender disconnects, the receiver returns to the idle screen.

The logo is this project's own design. `assets/make_logo.py` (Pillow) regenerates
`assets/logo.png` (idle screen) and `assets/logo.ico` (window and tray icon). Both are embedded
with `include_bytes!`. It is not the OpenDisplay app icon; swapping
it in is a one-file change.

- **Quit:** right-click the tray icon and choose **Quit od-receiver**, or press **Alt+F4**. The
  receiver sends `closing` (best-effort) before exiting.
- **F2** toggles the timing overlay. It shows every stage (net, decode, present, e2e), the queue
  and the drops, the ping RTT, and the sender's own health from its `ping`: capture fps, encoder
  and network drops, pending sends, and input latency.
- **Locking Windows** sends `sleeping` and closes the connection. While the session is locked,
  any sender that connects gets `hello`, then `sleeping`, then a close. After unlock it can
  reconnect.
- **stats:** every 5 s the receiver sends a `stats` message to the sender (fields below).

Release builds have no console window. They log to `%LOCALAPPDATA%\od-receiver\od-receiver.log`,
which is replaced on each start. Debug builds (`cargo run`) log to the console. A fatal startup
error, such as a bad config file or a port already in use, is also shown in a message box.

### Config

`%APPDATA%\od-receiver\config.json` is created with defaults on first run:

```json
{
  "port": 9000,
  "name": null,
  "maxEncodeWide": 4096,
  "maxEncodeHigh": 2304,
  "monitor": null
}
```

- `port` is the TCP port. The UDP cursor channel uses `port + 1`.
- `name` is the Bonjour name. `null` means the computer name.
- `maxEncodeWide` / `maxEncodeHigh` is the decode ceiling announced in `hello`. Portrait swaps them.
- `monitor` is `null` for the primary monitor. It can also be an index from the
  `monitor N: ...` lines at the top of the log, or a device name such as `"\\.\DISPLAY2"`.
  The GPU that drives that monitor is used for decode and present, so frames never cross
  adapters. If the monitor is not connected, the primary monitor is used.

Missing keys take their defaults. Unknown keys (typos) are an error.

### Windows Firewall

A Mac on the LAN must reach **TCP 9000** (session) and **UDP 9001** (cursor). Bonjour uses UDP
5353; Windows' built-in mDNS rule normally allows it on private networks. When the exe first
listens, Windows may ask whether to allow it, and accepting creates the rules. To add them by
hand from an elevated prompt (private networks only):

```
netsh advfirewall firewall add rule name="od-receiver TCP" dir=in action=allow protocol=TCP localport=9000 profile=private
netsh advfirewall firewall add rule name="od-receiver UDP" dir=in action=allow protocol=UDP localport=9001 profile=private
```

The receiver never changes firewall settings itself. Without the UDP rule the sender falls back
to cursor over TCP. Without the TCP rule nothing connects.

Input on the window goes to the sender, normalized to the video (not the screen):

- The left mouse button and the primary touch contact send `touch`.
- The mouse wheel and the precision touchpad send `scroll`.
- A pen sends `pencil` and `proximity`. With a sender below pv 3 it sends `touch` instead.

It also listens on **UDP 9001** for the cursor side channel (§6.3) and advertises it as
`hello.cursorPort` while bound. A sender on another machine needs both TCP 9000 and UDP 9001 open
in Windows Firewall; without UDP the sender falls back to TCP after a few seconds.

## Testing without a Mac

Generate an H.264 Annex B stream (no B-frames, SPS/PPS on every IDR):

```
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 10 -c:v libx264 -preset ultrafast -tune zerolatency -bf 0 -pix_fmt yuv420p -x264-params repeat-headers=1:keyint=120 -f h264 testdata/test-1080p60.h264
```

Then, with the receiver running:

```
cargo run --bin fake-sender -- testdata/test-1080p60.h264 auto 60
```

`auto` finds the receiver over Bonjour. Pass `host:port` to dial directly. The fake sender
re-frames the stream into one access unit per wire frame with 4-byte start codes, adds the
`{"cap","snd"}` telemetry prefix, answers `ping` with `pong`, and jumps to the next IDR on `kf`.
A fourth argument starts at that access unit (a non-IDR simulates joining mid-GOP).

`--no-welcome` skips `welcome`, so the receiver treats the fake sender as pv 1. Input messages
with `t` are printed with their age: the fake sender's clock minus `t`.

`--cursor` (before the file) also sends a `cursorImg` and circles the cursor at 120 Hz with
sequence numbers: over UDP when `hello` offers `cursorPort` (mirrored on TCP until `cursorAck`),
with a reordered and a stale datagram injected every 60 ticks, and a switch to a new UDP flow
after 4 s. It prints each `cursorAck` and how many messages the receiver should have dropped; the
receiver logs its own count as `cursor stale` every 5 s.

`decode-bench` feeds files through the receiver's real decode pipeline:

```
cargo run --release --bin decode-bench -- --fps 60 testdata/test-1080p60.h264
cargo run --release --bin decode-bench -- --throughput testdata/test-2304p60.h264
cargo run --release --bin decode-bench -- testdata/test-1080p60.h264 testdata/test-720p60.h264
```

## Decode measurements

RTX 3060 (driver 610.62), i7-12700, Windows 10 19045, release build, Microsoft H.264 decoder
MFT in low-latency mode with D3D11 output. "GPU complete" is measured by waiting on a D3D11
event query after each frame (bench only).

| Stream | Pacing | Decoder CPU p50 / p95 | Submit → GPU complete p50 / p95 |
|---|---|---|---|
| 1080p | 60 fps | 0.22 / 0.40 ms | 0.85–0.94 / 1.7–2.6 ms |
| 1080p | 144 fps | 0.18 / 0.43 ms | 0.41 / 0.86 ms |
| 3840×2160 | 60 fps | 0.25 / 0.48 ms | 0.47 / 0.83 ms |
| 4096×2304 | 60 fps | 0.25 / 0.43 ms | 0.53 / 0.75 ms |

- Every input access unit produces its picture within the same `ProcessInput`/`ProcessOutput`
  call, so the MFT adds no frames of reordering delay.
- Sustained rate without pacing is 632 fps at 1080p, 212 fps at 3840×2160 and 191 fps at
  4096×2304. The default 4096×2304 ceiling therefore has about 3× headroom at 60 fps.
- When fed faster than real time, the MFT throttles itself: about 10 frames, then a ~14 ms stall
  that lines up with the 15.6 ms Windows timer tick. A larger output pool does not change this.
  With `timeBeginPeriod(1)` the stall becomes ~1.8 ms on every frame instead. With live pacing
  neither happens, so the receiver leaves the timer resolution alone.
- The first frame after connect or a resolution change costs 18–25 ms (decoder creation is
  1.5–5 ms; the rest is the first IDR, including surface allocation).
- Decoded output is bit-exact with ffmpeg's software decoder (frame 100 of the 1080p test
  stream: 0 differing bytes).

## Presentation measurements

Same machine, primary monitor 1920×1080 at 165 Hz, release build, fake-sender over loopback at
60 fps, 1080p stream, overlay off.

- [PresentMon](https://github.com/GameTechDev/PresentMon) 2.6.0 over 10 s: all 597 presents are
  `Hardware: Independent Flip`, with `AllowsTearing=1` and `SyncInterval=0`.
- Present call (draw + `Present`, CPU): p50 0.07 ms, p95 0.13 ms. With the F2 overlay on, it is
  about 0.3 ms (Direct2D text).
- Sender capture → `Present` returned (the receiver's `e2e`): p50 0.8–1.2 ms, p95 1.2–1.5 ms.
  Network (send → socket read): 0.5–0.7 ms.
- `Present` → displayed (PresentMon `MsUntilDisplayed`) depends on the NVIDIA power setting:

  | Power management mode | GPU clocks while streaming | p50 | p95 |
  |---|---|---|---|
  | Default (Normal) | P8, about 250 MHz core and 405 MHz memory | 7.5 ms | 8.6 ms |
  | Prefer maximum performance | P0, 1852 MHz core and 7501 MHz memory | 1.8 ms | 1.9 ms |

  This is all GPU time. At this light load the default setting drops the RTX 3060 to P8 after
  about 2 s. There, the fullscreen NV12 → RGB draw alone takes 1.7 ms (timestamp queries), and
  waiting for the decoder takes most of the rest. **Recommended:** NVIDIA Control Panel → Manage
  3D settings → Program Settings → add `od-receiver.exe` → Power management mode → Prefer maximum
  performance. The profile is tied to the exe path. The receiver does not change driver settings
  itself.
- 4096×2304 streams downscaled to 1080p: the present call is the same (p50 0.06 ms).
- Rendered output is pixel-exact against a BT.709 limited-range conversion of the decoder's
  NV12, including the bottom row and the right column. A screenshot was compared with the
  decoded NV12, with a max difference of 0.

## Cursor measurements

Same setup, fake-sender `--cursor` (120 Hz cursor over UDP plus 60 fps 1080p video over TCP).

- One `cursorAck` per UDP flow (2 flows → 2 acks). The receiver's stale count equals the
  sender's expectation (TCP mirrors + injected stale datagrams), e.g. 34 vs 34.
- With a 1 fps stream, two screenshots 150 ms apart differ only around the cursor: cursor updates
  re-present the last frame on their own.
- Video e2e with cursor traffic: p50 0.8–1.1 ms, p95 1.3–1.6 ms (without: p50 0.7 ms, p95
  1.1–1.2 ms). Present call p50 0.03–0.05 ms.
- The first version retried a busy swap chain with a 1 ms sleep, which Windows rounds up to the
  15.6 ms timer tick: video e2e p95 rose to 9.4 ms once cursor redraws kept the swap chain busy.
  The decode thread now waits on the frame-latency handle (at most 4 ms) instead.

## Input measurements

Same setup. Real Windows input was injected while fake-sender ran: mouse with `SendInput`, touch
and pen with `InjectSyntheticPointerInput`. The injector is a throwaway test tool and is not in
the repo.

- **Mouse drag.** A drag from pixel (0,0) through (960,540) to (1919,1079) gives `began` (0,0),
  `moved` (0.5,0.5), `moved` (0.99948,0.99907), then `ended`. Normalization is checked against
  the letterbox and pillarbox rects in unit tests.
- **Wheel.** One notch forward gives `scroll dy +48`. One notch right gives `dx −48`. Two notches
  back give `dy −96`.
- **Pen.** Tilt X 45° gives altitude π/4 and azimuth 0. Pressure 512/1024 gives 0.5. The pen
  produces this sequence: `proximity` entering, `hover`, `down`, `move`, `up`, `hover`,
  `proximity` leaving.
- **pv 1 sender.** The same pen strokes arrive as `touch` began/moved/ended, with no `pencil` or
  `proximity`.
- **Latency.** UI event → the sender's socket read is within ±0.4 ms of zero on loopback. That is
  below the error of the clock offset, so it only shows the input path adds well under 1 ms.
- **UI thread.** It never writes to the socket. Input goes through a bounded queue
  (`try_send`, 256 entries) to an `input-tx` thread. A stalled connection (up to the 5 s write
  timeout) delays input but never freezes the window.

## Stats measurements

Same setup, fake-sender at 60 fps 1080p over loopback. `stats` arrives every 5 s, for example:

```json
{"type":"stats","transport":"usb","fps":60.2,"mbps":28.1,"dec50":0.25,"ph50":0.034,"ph95":0.308,
 "e2e50":1.17,"e2e95":1.94,"offsetKnown":true,"rtt":0.12,"stalls":0,"kf":0,"drops":0}
```

- Lock and quit were checked by posting `WM_WTSSESSION_CHANGE` and `WM_CLOSE` to the window,
  which is the same code path as a real lock and as Alt+F4. On lock the sender got `sleeping`, a
  sender connecting while locked was turned away, and after unlock a sender could connect again.
  On quit the sender got `closing` and the process exited.
- With `"monitor": 3` on this one-monitor PC, the log warns and the primary is used. The adapter
  is matched through its DXGI output (`\\.\DISPLAY1` → NVIDIA GeForce RTX 3060).

## Where the spec is ambiguous, and what this receiver does

- **Max inbound frame size.** The spec sets no sender-to-receiver maximum. This receiver
  drops the connection on any frame over 32 MiB, so garbage input cannot exhaust memory.
- **Zero-length inbound frame.** Not forbidden sender-to-receiver. It fails the JSON
  test, so it is classified as video, and the video path ignores it.
- **Deprecated `hello.pixelsWide/High/scale`.** The receiver sends the monitor's physical
  pixels and DPI scale, matching the iOS receiver's semantics. The authoritative values
  go in `hello.panel`. `panel.pointsWide/High` is omitted because Windows has no Mac-style
  "looks like" resolution setting.
- **`videoCaps`.** Not sent, so the sender stays on the legacy H.264 stream.
- **Replacing a live connection.** §1 says a new inbound connection MUST replace the current
  one. §6.4 mentions the official receiver waiting until a newcomer "proves itself with bytes".
  This receiver follows §1 and replaces the old connection immediately.
- **Decode queue depth.** The brief asked for no queue deeper than 1, and for dropping to the
  newest frame when the decoder falls behind. But every H.264 P-frame is a reference, so a
  dropped frame corrupts the picture until the next IDR. So up to 3 frames may wait for the
  decoder, which absorbs a one-off stall. If that queue overflows, everything queued is dropped
  and `kf` is sent. Presentation (milestone 4) always shows only the newest decoded frame.
- **Keyframe requests.** `kf` is sent immediately when the first frame after connect (or after
  a loss) is not an IDR, 500 ms after connect if no video arrived, and then at most once per
  second until an IDR arrives.
- **Color space.** The spec does not say what color space the video is in. The receiver
  converts with BT.709 limited range, which is the HD default, and does not read the SPS VUI. A
  stream encoded as BT.601 (for example ffmpeg's `testsrc2` test stream) shows slightly shifted
  colors.
- **`updateRequired`.** The receiver shows the message and the store URL in a message box. It
  keeps decoding and presenting whatever video still arrives, because §6.2 says the sender may
  keep streaming.
- **Re-`hello`.** When the monitor's size, position, refresh rate or DPI scale changes
  (`WM_DISPLAYCHANGE` / `WM_DPICHANGED`), `hello` is re-sent on the live session. In portrait,
  `maxEncodeWide/High` are swapped (§6.5).
- **Who may send cursor datagrams.** The spec only says to accept the most recent flow. This
  receiver also requires the datagram's source IP to equal the live TCP sender's IP (the sender
  dials the same host), and ignores datagrams while no sender is connected, so another host on
  the LAN cannot move the cursor.
- **Flow switching.** Any datagram from a new source address:port starts a new flow (tracker
  reset, new `cursorAck`), even if that address was seen before. A new TCP connection also
  forgets the current flow, so the sender's next datagram is acked again.
- **UDP datagram without `s`.** Dropped: §6.3 makes `s` part of the datagram format. Only a TCP
  `cursor` without `s` applies unconditionally.
- **Cursor after (re)connect.** Hidden until the new sender sends `cursor`. The last sprite is
  kept until a new `cursorImg` replaces it.
- **`cursor` visible without `x`/`y`.** Keeps the last position.
- **`cursorImg` limits.** Sprites larger than 1024×1024 or with non-finite geometry are rejected
  (no cursor until the next valid one); `nw/nh/ax/ay` are clamped to 0..1. The cursor is drawn
  only while a video frame is on screen and is not clipped to the letterboxed video rect.
- **Input outside the video.** A press or pen-down that begins in the letterbox bars is
  ignored until it ends. A contact that began inside and moves outside is clamped to 0..1. Pen
  hover and `proximity` are only sent inside the video.
- **Mouse as touch.** The left button sends `touch` (there is no mouse message in the protocol).
  A mouse move without a pressed button sends nothing. The right and middle buttons are ignored.
  Only one contact at a time: while the mouse owns the contact, touch is ignored, and the other
  way around. Only the primary touch contact counts.
- **Wheel scale.** One notch (120 units) is 48 window pixels: 3 lines of 16 px. That is scaled
  to video pixels by the video size divided by the drawn size. A precision touchpad's smaller
  wheel deltas scale the same way.
- **Pen orientation.** Windows tilt X and Y become a barrel direction (tan tiltX, tan tiltY),
  with +Y meaning toward the user (screen down). Azimuth is atan2(y, x) in screen coordinates
  with y down. Altitude is atan2(1, |direction|). With no tilt data, altitude is π/2 and azimuth
  is 0. With no pressure data, pressure is 1 in contact. `rotation` is always 0.
- **Pen fallback.** For a sender below pv 3 (including before `welcome` arrives), the mapping
  is: `down`→`began`, `move`→`moved`, `up`→`ended`. Hover and `proximity` are dropped.
- **Input `t`.** Stamped when the UI thread handles the message, not from the OS event time.
  Omitted until the clock offset is known.
- **`stats` fields.** None are normative, so these are this receiver's definitions:
  - `transport`: `"usb"` for a loopback peer (a forwarded cable), `"wifi"` otherwise.
  - `fps`: frames presented per second.
  - `mbps`: video payload megabits per second.
  - `dec50`: decoder CPU time.
  - `ph50`/`ph95`: draw + `Present` time.
  - `e2e50`/`e2e95`: sender capture → `Present`, only when the clock offset is known.
  - `rtt`: the minimum ping RTT.
  - `stalls`: decoded frames that were never shown because a newer one replaced them first.
  - `kf` and `drops` count since the connection started.
- **Session lock.** `sleeping` means "device locked, reconnect on wake expected". Windows keeps
  running while locked, so a sender could reconnect at once. A sender that connects while the
  session is locked therefore gets `hello` (always first, §6.1), then `sleeping`, and is
  disconnected. The listener and Bonjour stay up.
- **Quit.** `closing` is sent with the socket's normal 5 s write timeout. A sender that stopped
  reading can delay quitting by up to 5 s.
- **Bonjour addresses.** Loopback interfaces are not advertised, so a sender never dials
  its own `::1`. The listener is dual-stack, so IPv4 and link-local IPv6 dials both work.
