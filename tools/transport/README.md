# Transport test tools

Replays real video frame sizes over TCP, UDP or QUIC between two Macs and measures what a receiver would see: frame latency, lost frames, and hitches. The tools produced [research/transport-2026-09-30](../../research/transport-2026-09-30/README.md).

| Tool | What it does |
|---|---|
| `nettest.swift` | `trace`: hardware-encodes synthetic scrolling text with the app's encoder settings and writes one frame size per line. `recv`: the receiver, listening on all transports. `send <host> <mode> <trace>`: replays a trace. Modes: `tcp`, `quic1`, `quicN`, `udp`, `udpnack`, `qdgram`, `qdgramnack`. Options: `pace=<Mbps>`, `inflight=<n>`, `svc=video\|responsive\|signaling`. |
| `build.sh` | Builds for both Macs, makes a throwaway TLS identity for QUIC, and copies everything to `/tmp/nettest` on the receiver (`OD_RECEIVER_HOST`, default `imac`). |
| `matrix.sh <host> <link> <rounds> <secs> <trace...>` | Runs every mode interleaved and appends JSON results (`MODES`, `OUT`, and `LOAD=1` as a label for runs with a bulk copy alongside). |
| `agg.py`, `fmt.py` | Summarise results across rounds, or one line per run. |
| `probe.py` | A 200 Hz UDP echo that shows how often a link stalls and at what spacing. It found the AirDrop "Everyone" stalls. |

The receiver's QUIC listener imports the identity into a temporary file keychain, because over ssh the login keychain is locked. The traffic is random bytes, so runs never carry anything from your screen.
