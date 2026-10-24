# Android receiver test tools

Python 3 stdlib only, plus `ffmpeg` with libx264/libx265 (Homebrew's build
works). Both scripts follow [PROTOCOL.md](../../PROTOCOL.md) (pv 3).

## fake-sender.py

A scripted sender: dials a receiver, waits for `hello`, replies `welcome`,
sends `streamConfig`, then streams an ffmpeg `testsrc2` pattern (moving
pattern, timecode and frame counter in the top-left corner; both restart
at 0 whenever the encoder restarts) with a circling cursor, pings and pongs.

```sh
# Android receiver on the phone, reached over USB:
adb forward tcp:9000 tcp:9000       # host:9000 -> phone:9000 (forward, not reverse)
python3 tools/android/fake-sender.py --duration 30

# common options
--host 192.168.1.20 --port 9000    # dial a receiver on the LAN
--codec auto|h264|hevc             # auto = hevc if hello.videoCaps offers it
--size 1080x2424 --fps 60          # default: hello.panel, clamped by videoCaps
--bitrate 8M
--udp-cursor                       # also send cursor datagrams to hello.cursorPort
--send-sleeping-at 10              # send {type: sleeping}, pause video 3 s, resume
--rotate-test                      # rotate the phone; exit nonzero if no re-hello
-v                                 # ffmpeg command line, every IDR, receiver pings
```

Exit code: 0 OK, 2 no `hello` (or connect failed), 3 connection dropped
early, 4 `hello` failed validation, 5 `--rotate-test` saw no rotation.

How it behaves:

* Video is one access unit per wire frame, 4-byte start codes only (x264
  emits 3-byte ones between slices; they are rewritten), telemetry prefix
  `{"cap","snd"}` on every frame, long GOP (keyint 600, no scene cuts), no
  B-frames, `repeat-headers=1` so IDRs carry SPS/PPS (HEVC: VPS/SPS/PPS).
* `kf`, a re-`hello` with a new size, and the resume after
  `--send-sleeping-at` all **restart the ffmpeg encoder**. A fresh encoder's
  first frame is always an IDR with parameter sets; frames from the old
  process are discarded. The IDR goes out about 40 ms (H.264) / 70 ms
  (HEVC) after the request at 1080x2424.
* Pacing comes from ffmpeg's `realtime` filter (`-re` sends a 0.5 s burst
  first). Pings run on their own thread, so a stalled ffmpeg cannot trip the
  receiver's 5 s liveness timeout.
* Every receiver message type is counted; `touch`, `scroll`, `pencil`,
  `proximity` and `stats` are printed in full.

## mock-receiver.py

A validating stand-in receiver for testing the sender itself (or any other
sender) on localhost. It sends a Pixel 10a hello (panel 1080x2424 @2.625,
videoCaps h264 + hevc 2424x2424@120), pings every 2 s, sends `kf` after 3 s,
and checks the demux rule, telemetry prefix, 4-byte start codes, one
picture per frame, and that the first frame of the session, after `kf` and
after a stream change is an IDR with parameter sets.

```sh
python3 tools/android/mock-receiver.py --port 19000 &
python3 tools/android/fake-sender.py --port 19000 --duration 8

# more coverage
python3 tools/android/mock-receiver.py --port 19000 --udp-port 19001 --rotate-at 5 \
    --expect-codec hevc --dump /tmp/hevc.es &
python3 tools/android/fake-sender.py --port 19000 --duration 9 --udp-cursor --rotate-test
ffmpeg -v error -i /tmp/hevc.es -f null -   # offline decode check
```

`--no-hevc` offers only H.264. Exits 0 on PASS, 1 on FAIL.
