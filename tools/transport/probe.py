#!/usr/bin/env python3
"""Wi-Fi stall probe: small UDP echo at a fixed rate, RTT timeline.
  probe.py echo [port]                       (receiver)
  probe.py send <host> [seconds] [hz] [port] (sender; prints stall stats and period histogram)"""
import socket, sys, time, struct, collections
if sys.argv[1] == 'echo':
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('', int(sys.argv[2]) if len(sys.argv) > 2 else 9200))
    while True:
        d, a = s.recvfrom(64); s.sendto(d, a)
host = sys.argv[2]; secs = float(sys.argv[3]) if len(sys.argv) > 3 else 30; hz = int(sys.argv[4]) if len(sys.argv) > 4 else 200
port = int(sys.argv[5]) if len(sys.argv) > 5 else 9200
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.setblocking(False)
sent = {}; rtt = {}; t0 = time.monotonic(); i = 0; iv = 1 / hz
while time.monotonic() - t0 < secs + 1:
    now = time.monotonic()
    if now - t0 < secs and now >= t0 + i * iv:
        s.sendto(struct.pack('!I', i), (host, port)); sent[i] = now; i += 1
    try:
        while True:
            d, _ = s.recvfrom(64); k = struct.unpack('!I', d)[0]; rtt[k] = (time.monotonic() - sent[k]) * 1000
    except BlockingIOError:
        pass
    time.sleep(0.0003)
vals = sorted(rtt.values()); n = len(vals)
print(f"sent {i} got {n} lost {i-n}  rtt p50 {vals[n//2]:.1f} p95 {vals[int(n*.95)]:.1f} p99 {vals[int(n*.99)]:.1f} max {vals[-1]:.1f} ms")
# stall = run of probes with rtt > 30 ms; report start times and spacing
starts = []; prev = False
for k in range(i):
    bad = rtt.get(k, 999) > 30
    if bad and not prev: starts.append(k * iv)
    prev = bad
gaps = [round(b - a, 2) for a, b in zip(starts, starts[1:])]
print(f"stalls >30ms: {len(starts)} in {secs:.0f}s ({len(starts)/secs:.2f}/s)")
print("spacing histogram (s):", sorted(collections.Counter(round(g, 1) for g in gaps).items(), key=lambda x: -x[1])[:10])
# typical stall shape: peak rtt per stall
peaks = []
for st in starts:
    k0 = int(st / iv); pk = 0
    while k0 < i and rtt.get(k0, 999) > 30: pk = max(pk, rtt.get(k0, 999)); k0 += 1
    peaks.append(round(pk))
print("stall peaks (ms):", sorted(peaks)[len(peaks)//2] if peaks else '-', "median;", max(peaks) if peaks else '-', "max")
