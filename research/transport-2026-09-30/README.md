# Transport spike: TCP vs UDP vs QUIC

Research snapshot: 2026-09-30, against `main` at v1.23.0 (`57029c7`).

**Question:** would moving video off TCP, to raw UDP or to QUIC, give a crisper picture, more frames per second, or smoother motion?

**Short answer:** no transport change is worth making right now.
- **On a cable,** TCP is already the best of all eight options.
- **On Wi-Fi,** almost all of the stutter came from AirDrop being set to "Everyone" on the sending Mac. That is a radio setting, and every transport stalls the same way under it.
- **With AirDrop quiet,** UDP with resends of lost pieces roughly halves TCP's worst frame (about 58 ms down to about 30 ms at 5K). QUIC through Network.framework was less stable than TCP.
- **On a busy network** (a large file copy running alongside), every transport queues the same way. That calls for bitrate adaptation, not a different transport.

## Setup

- **Sender:** MacBook Pro M5 Pro, macOS 27.0.
- **Receiver:** iMac 27" 5K (2017, Intel), macOS 13.7.
- **Wi-Fi:** both Macs on the same 5 GHz access point, channel 116, 80 MHz. The M5 links at 802.11ax (648 Mbit/s); the iMac at 802.11ac.
- **Thunderbolt Bridge:** the same two Macs, connected by cable.

The test tool is `tools/transport/nettest.swift`. It replays frame sizes from a real VideoToolbox encode, using the app's encoder settings, at 60 Hz or 30 Hz. The receiver records when each frame is complete, using a clock offset measured at the start of every run (minimum-RTT ping exchange).

**Frame-size traces:**

| Trace | Content | Frame sizes |
|---|---|---|
| `t5k30` | HEVC 5120x2880 at 30 fps, target 18 Mbps: scrolling text with a full content change every 3 s | median 14 KB, largest 944 KB |
| `t5k30max` | The Best preset's ceiling at 5K | 75 KB per frame (18 Mbps), plus a 600 KB frame every 3 s |
| `t1440p60max` | 2560x1440 at 60 fps | 37.5 KB per frame (18 Mbps), plus a 300 KB frame every 3 s |

**Transports:**

| Mode | What it is |
|---|---|
| `tcp` | What the app does today: length-prefixed frames on one TCP connection with `noDelay`, and at most 3 frames waiting on their send completion before the sender drops at the source (`MacSender.maxPendingSends`). |
| `quic1` | One QUIC stream carrying the same framing. |
| `quicN` | A new QUIC stream per frame, so a late frame cannot hold up the next one in transit. |
| `udp` | Frames split into 1200-byte datagrams, never resent. |
| `udpnack` | As `udp`, plus the receiver asks for the missing pieces of a frame as soon as a newer frame arrives, or after 4 ms of silence (to catch a lost tail). It re-asks at most every 15 ms. |
| `qdgram`, `qdgramnack` | QUIC datagrams (RFC 9221), without and with the same resend requests. |
| `pace=150` | Sends each frame's datagrams spread out at 150 Mbit/s instead of all at once. |

**Metrics:**
- Latency is from the sender handing over a frame to the frame being complete on the receiver.
- "Serial" latency also makes frame N wait for frame N-1, as the decoder does, because each frame references the one before it.
- A hitch is a gap of more than two frame intervals between frames that could be shown.
- A lost frame in the datagram modes breaks the reference chain until a keyframe arrives, so each one counts as a visible glitch.

## 1. Thunderbolt cable: TCP wins

Heavy 5K trace (`t5k30max`), 20 s per run:

| Mode | Median | 99th percentile | Worst | Lost frames |
|---|---|---|---|---|
| **tcp** | **0.6 ms** | **1.5 ms** | **3 ms** | 0 |
| quic1 | 1.2 | 3.8 | 6 | 0 |
| quicN | 2.0 | 5.1 | 8 | 0 |
| udp | 2.9 | 4.6 | 16 | 6 |
| udpnack | 2.8 | 20.3 | 24 | 0 |
| qdgram | 7.1 | 16.2 | 30 | 0 |

- Nothing is lost on the wire here, so TCP's reliability costs nothing. Its kernel path is the cheapest.
- Raw UDP loses frames even on the cable, because a 600 KB frame bursts about 500 datagrams at once and overflows a socket buffer.
- QUIC runs in user space, with encryption and congestion control, and costs 1–7 ms per frame on the Intel receiver.
- The iPhone and iPad USB path (usbmuxd) only tunnels TCP, so UDP and QUIC are not even available there.

## 2. Wi-Fi with AirDrop set to "Everyone": the radio, not the transport

The first round on Wi-Fi showed the same floor for every transport:
- about 40 hitches per 20 s;
- about 50 ms at the 95th percentile;
- about 72 ms at the 99th percentile.

A 200 Hz UDP echo probe (`tools/transport/probe.py`) shows why:

| M5 to iMac over Wi-Fi | Median RTT | 95th percentile | Stalls over 30 ms |
|---|---|---|---|
| AirDrop "Everyone" | 3.9 ms | 55–63 ms | **2.0–2.75 per second**, one every 0.5 s, each peaking at about 75 ms, with no loss |
| AirDrop "Contacts Only" | 3.8 ms | 6.4 ms | 1 in 20 s |
| AirDrop "No One" | 3.8 ms | 6.2 ms | 2 in 20 s |
| Thunderbolt (for comparison) | 0.6 ms | 1.1 ms | 0 |

- Pinging the router from each Mac separately puts the stall on the M5. It stalls every 0.40–0.42 s.
- The iMac's own link to the router stays at a worst case of 6 ms.
- In discoverable-to-everyone mode, the M5's radio regularly leaves the infrastructure channel for AWDL, the peer-to-peer link behind AirDrop. Packets wait meanwhile rather than being lost, so no transport can help.
- Setting `NWParameters.serviceClass = .interactiveVideo` on the video connection made no difference, for TCP or for UDP.

Under these conditions the transports differed only in the rare long tail. Heavy 5K trace, two runs each:

| Mode | 95th percentile | Worst (run 1, run 2) | Frames over 100 ms | Lost | Hitches per 20 s |
|---|---|---|---|---|---|
| tcp | 57 ms | 348, 80 | 8 | 0 | 38–39 |
| quic1 | 53 | 169, 150 | 6 | 0 | 39–40 |
| quicN | 69 | 92, 232 | 5 | 0 | 39–40 |
| udp | 53 | 80, 94 | 0 | 1 | 38 |
| **udpnack** | 54 | **80, 91** | **0** | **0** | 38–39 |
| qdgram | 55 | 81, 83 | 0 | 1 | 37–38 |
| qdgramnack | 61 | 89, 195 | 7 | 0 | 38–40 |

The two other traces had the same shape. The single exception was one plain `udp` run at 1440p60, whose worst frame took 598 ms with no loss: a one-off stall on the air.

- **Spreading sends out (`pace=150`)** never helped. It added 1–2 ms to the median and triggered more resend requests.
- **A stream per frame (`quicN`)** had twice the median latency of TCP. At 60 fps the sender also dropped 6% of frames at the source, because streams took too long to open and complete.

## 3. Wi-Fi with AirDrop quiet: a modest gain for UDP with resends

With AirDrop set to "Contacts Only", two runs each:

| Trace | Mode | Median | 95th percentile | 99th percentile | Worst (run 1, run 2) | Lost | Frames over 100 ms |
|---|---|---|---|---|---|---|---|
| 5K 18 Mbps | tcp | 5.7 ms | 8.2 | 18.4 | 58, 52 | 0 | 0 |
| | udp | 7.0 | 10.0 | 22.2 | 30, 27 | 1 | 0 |
| | **udpnack** | 6.9 | 9.6 | 23.0 | **30, 28** | 0 | 0 |
| | quic1 | 5.5 | 9.2 | 26.8 | 164, 53 | 0 | 3 |
| | qdgram | 8.2 | 11.8 | 38.5 | 69, 163 | 0 | 3 |
| 1440p60 18 Mbps | tcp | 4.2 | 6.6 | 12.8 | 39, 44 | 0 | 0 |
| | udp | ~1.4\* | 5.2 | 8.2 | 18, 20 | 0 | 0 |
| | **udpnack** | 4.5 | 6.5 | 10.7 | **15, 16** | 0 | 0 |
| | quic1 | 3.5 | 6.0 | 184.9 | 582, 107 | 0 | 18 (83 source drops) |
| | qdgram | 5.7 | 8.4 | 19.1 | 38, 106 | 0 | 1 |

\* In one run the clock offset estimate was a few milliseconds off (the median read −2.1 ms), so this median is low. The spread between median and tail is not affected.

- **TCP** with quiet AirDrop has no hitches and keeps 99% of frames under about 18 ms.
- **UDP with resends** cuts the worst frame roughly in half and loses nothing.
- **QUIC** through Network.framework had sudden 100–580 ms stalls in half of its runs, plus source drops at 60 fps, which none of the other modes showed.

## 4. Busy Wi-Fi: every transport queues

1440p60 at 18 Mbps, AirDrop quiet, with a bulk TCP upload (`ssh cat`) from the sender to the receiver running at the same time. One run each:

| Mode | Median | 95th percentile | 99th percentile | Worst | Lost | Hitches per 20 s |
|---|---|---|---|---|---|---|
| tcp | 13.9 ms | 26.9 | 53.5 | 150 | 0 | 33 |
| udpnack | 15.9 | 27.9 | 35.3 | 69 | 1 | 50 |
| qdgram | 15.1 | 27.3 | 64.2 | 152 | 3 | 37 |
| quic1 | 15.5 | 33.7 | 57.1 | 145 | 0 | 63 |

The bulk flow fills the access point's queue, and every transport's median rises by about 10 ms. None of them adapts the video to the space left. That takes bitrate adaptation driven by delay (WebRTC's GCC and Apple's FaceTime both do this). Today the sender uses a fixed `AverageBitRate` per preset.

## Conclusions

1. **Cable:** keep TCP. Nothing to gain.
2. **Wi-Fi:**
   - Set AirDrop to "Contacts Only" or "No One" on the sending Mac. That one setting takes the Wi-Fi hitch rate from about 2 per second to about 1 per 20 s, and the 95th percentile from about 55 ms to about 8 ms. It belongs in the FAQ.
   - The sender is not sandboxed, so it could also read `com.apple.sharingd DiscoverableMode` and hint at the setting when it streams over Wi-Fi.
3. **QUIC** is not worth it here:
   - it is slower than TCP on a cable;
   - it is not steadier than TCP on Wi-Fi;
   - datagrams need macOS 13 and iOS 16, above the app's minimums of macOS 12 and iOS 15;
   - it needs a TLS identity on every receiver.

   The one real benefit would be encryption; today the stream crosses the network as plain text. If that becomes a goal, TLS over the existing TCP connection is the smaller change.
4. **UDP with resends (`udpnack`)** is the only mode that improved on TCP on Wi-Fi:
   - it halves the worst frame on quiet Wi-Fi (about 58 ms down to about 30 ms at 5K, and about 44 ms down to about 16 ms at 1440p60);
   - it avoids TCP's occasional 150–350 ms tail during interference.

   It would be a Wi-Fi-only video path next to the TCP control connection. The app would have to own reassembly, resend requests, keyframe recovery for frames that are truly lost, and a rate limit, because UDP has no congestion control. That is a moderate project for a gain users would mostly notice as fewer rare long freezes, not as more frames per second.
5. **For frame rate and sharpness,** the levers are still the encoder, not the network. HEVC at 5K is encoder-bound at about 29 fps (`research/hevc-m5-2026-09-29`). HEVC 5K needs about 6–18 Mbps, against about 15 Gbit/s on Thunderbolt and several hundred Mbit/s on this Wi-Fi.

## Reproduce

```sh
tools/transport/build.sh                  # builds both architectures, TLS identity, copies to the receiver
build/transport/nettest trace build/transport/t5k30.txt 5120 2880 30 18 hevc 20
ssh imac 'cd /tmp/nettest && ./nettest recv 9100'
tools/transport/matrix.sh 192.168.178.75 wifi 2 20 t5k30max.txt t1440p60max.txt
python3 tools/transport/agg.py build/transport/results.jsonl
ssh imac 'python3 /tmp/nettest/probe.py echo 9200' & python3 tools/transport/probe.py send 192.168.178.75 30 200
```

The raw results are in `results/` (one JSON line per run).
