#!/usr/bin/env python3
"""Mock OpenDisplay receiver that validates a sender against PROTOCOL.md (pv 3).

Listens on TCP, sends a Pixel-10a-like hello (panel 1080x2424 @2.625,
videoCaps h264 + hevc 2424x2424@120), pings every 2 s, requests one `kf`
after --kf-at seconds, optionally re-hellos rotated, and checks every frame:

  * demux rule: JSON iff len < 32768, first byte '{', no NUL
  * video: parseable telemetry prefix {"cap","snd"}, 4-byte start codes only,
    exactly one picture per frame (one first-slice VCL, and it comes first)
  * first frame of the session, first after `kf`, and first after a stream
    change are IDRs carrying parameter sets (H.264: 7+8 before 5; HEVC:
    32+33+34 before 19/20/21)
  * streamConfig before video; welcome for every hello; pong for every ping;
    cursor `s` strictly increasing across TCP and UDP
  * liveness: drops after > 5 s of silence like the official receiver

Exits 0 on pass, 1 on fail. Stdlib only. Optional --dump writes the video
elementary stream (prefix stripped) for an offline ffmpeg decode check.
"""

import argparse
import base64
import json
import socket
import struct
import sys
import threading
import time
from collections import Counter

IDR_H264 = {5}
IDR_HEVC = {19, 20, 21}


def now_ms():
    return int(time.time() * 1000)


def log(*a):
    print("[mock]", *a, flush=True)


class Check:
    def __init__(self):
        self.fails = []
        self.notes = []

    def fail(self, msg):
        if len(self.fails) < 50:
            log("FAIL:", msg)
        self.fails.append(msg)


def frame(obj):
    p = json.dumps(obj, separators=(",", ":")).encode()
    return struct.pack(">I", len(p)) + p


def is_json_frame(p):
    return len(p) < 32768 and p[:1] == b"{" and b"\x00" not in p


def split_nals(es):
    """Split on the 4-byte start code only (receivers MAY do exactly that)."""
    parts = es.split(b"\x00\x00\x00\x01")
    return [n for n in parts[1:]]


class Session:
    def __init__(self, conn, args, chk):
        self.c = conn
        self.a = args
        self.chk = chk
        self.wlock = threading.Lock()
        self.alive = True
        self.t0 = time.monotonic()
        self.last_rx = time.monotonic()
        self.counts = Counter()
        self.codec = None
        self.stream = None
        self.video_frames = 0
        self.video_bytes = 0
        self.idrs = 0
        self.expect_idr = "session start"
        self.expect_since = None
        self.non_idr_while_expecting = 0
        self.idr_latencies = []
        self.pings_out = {}
        self.rtts = []
        self.hellos_sent = 0
        self.welcomes = 0
        self.cursor_s = 0
        self.cursor_tcp = 0
        self.cursor_udp = 0
        self.cursor_dupes = 0
        self.cursor_img = False
        self.sender_pings = 0
        self.tel_lat = []
        self.first_video_ms = None
        self.dump = open(args.dump, "wb") if args.dump else None
        self.panel = (1080, 2424)
        self.udp_acked = False

    def send(self, obj):
        with self.wlock:
            try:
                self.c.sendall(frame(obj))
            except OSError:
                self.alive = False

    def hello(self, rotated=False):
        w, h = self.panel
        if rotated:
            w, h = h, w
        msg = {"type": "hello", "pixelsWide": w, "pixelsHigh": h, "scale": 2.625,
               "device": "Android", "id": "MOCK-ANDROID-0001", "pv": 3,
               "displayMaxFrameRate": 120,
               "panel": {"pixelsWide": w, "pixelsHigh": h, "scale": 2.625},
               "videoCaps": [{"codec": "h264", "maxWidth": max(w, h), "maxHeight": max(w, h),
                              "maxFrameRate": 120},
                             {"codec": "hevc", "maxWidth": 2424, "maxHeight": 2424,
                              "maxFrameRate": 120}]}
        if self.a.no_hevc:
            msg["videoCaps"] = msg["videoCaps"][:1]
        if self.a.udp_port:
            msg["cursorPort"] = self.a.udp_port
        self.hellos_sent += 1
        self.send(msg)

    def pinger(self):
        while self.alive:
            time.sleep(2)
            t = now_ms()
            self.pings_out[t] = time.monotonic()
            self.send({"type": "ping", "t": t})
            self.send({"type": "stats", "transport": "mock", "fps": self.video_frames})

    def script(self):
        time.sleep(self.a.kf_at)
        if self.alive:
            log(f"sending kf at {time.monotonic() - self.t0:.1f}s")
            self.send({"type": "kf"})
            self.expect_idr, self.expect_since = "kf", time.monotonic()
            self.non_idr_while_expecting = 0
            self.send({"type": "touch", "phase": "began", "x": 0.25, "y": 0.5})
            self.send({"type": "scroll", "dx": 0, "dy": 12.5})
        if self.a.rotate_at:
            time.sleep(max(0, self.a.rotate_at - (time.monotonic() - self.t0)))
            if self.alive:
                log(f"re-hello rotated at {time.monotonic() - self.t0:.1f}s")
                self.hello(rotated=True)

    def watchdog(self):
        while self.alive:
            time.sleep(0.2)
            if time.monotonic() - self.last_rx > 5:
                self.chk.fail("liveness: > 5 s without bytes from sender")
                self.alive = False
                try:
                    self.c.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def on_udp(self, data):
        try:
            m = json.loads(data)
        except ValueError:
            self.chk.fail("unparseable UDP datagram")
            return
        if m.get("type") != "cursor" or not isinstance(m.get("s"), int):
            self.chk.fail(f"bad UDP datagram {data[:80]!r}")
            return
        self.cursor_udp += 1
        self.cursor_seq(m)
        if not self.udp_acked:
            self.udp_acked = True
            self.send({"type": "cursorAck"})

    def cursor_seq(self, m):
        s = m.get("s")
        if s is None:
            return
        if s <= self.cursor_s:
            self.cursor_dupes += 1  # legal: TCP mirror of a datagram, or reordering
        else:
            self.cursor_s = s

    def on_control(self, p):
        try:
            m = json.loads(p)
        except ValueError:
            self.chk.fail(f"JSON-classified frame does not parse: {p[:80]!r}")
            return
        t = m.get("type")
        if not isinstance(t, str):
            self.chk.fail(f"control without type: {p[:80]!r}")
            return
        self.counts[t] += 1
        if t == "welcome":
            self.welcomes += 1
            if m.get("pv") != 3 or "min" not in m:
                self.chk.fail(f"bad welcome {m}")
        elif t == "pong":
            sent = self.pings_out.pop(m.get("t"), None)
            if sent is None:
                self.chk.fail(f"pong echoes unknown t {m.get('t')}")
            else:
                self.rtts.append((time.monotonic() - sent) * 1000)
            if not isinstance(m.get("mt"), (int, float)):
                self.chk.fail("pong without numeric mt")
        elif t == "streamConfig":
            self.codec = m.get("codec")
            self.stream = (m.get("width"), m.get("height"), m.get("framesPerSecond"))
            log(f"streamConfig {m}")
            if self.codec not in ("h264", "hevc"):
                self.chk.fail(f"streamConfig codec {self.codec!r}")
            w, h = m.get("width"), m.get("height")
            if not (isinstance(w, int) and isinstance(h, int) and w % 2 == 0 and h % 2 == 0):
                self.chk.fail(f"streamConfig size {w}x{h} not even ints")
            if self.video_frames > 0 and self.expect_idr is None:
                self.expect_idr, self.expect_since = "stream change", time.monotonic()
                self.non_idr_while_expecting = 0
        elif t == "cursor":
            self.cursor_tcp += 1
            if m.get("v") not in (0, 1):
                self.chk.fail(f"cursor v {m.get('v')}")
            self.cursor_seq(m)
        elif t == "cursorImg":
            self.cursor_img = True
            png = base64.b64decode(m.get("png", ""))
            if not png.startswith(b"\x89PNG\r\n\x1a\n") or len(png) >= 24000:
                self.chk.fail("cursorImg png invalid or too big")
            for k in ("nw", "nh", "ax", "ay"):
                if not isinstance(m.get(k), (int, float)):
                    self.chk.fail(f"cursorImg missing {k}")
        elif t == "ping":
            self.sender_pings += 1

    def on_video(self, p):
        self.video_frames += 1
        self.video_bytes += len(p)
        if self.first_video_ms is None:
            self.first_video_ms = time.monotonic()
        if self.codec is None:
            self.chk.fail("video before streamConfig")
            self.codec = "h264"
        sc = p.find(b"\x00\x00\x00\x01")
        if sc < 0:
            self.chk.fail("video frame without 4-byte start code")
            return
        if sc > 0:
            try:
                tel = json.loads(p[:sc])
                if not isinstance(tel.get("cap"), (int, float)) or not isinstance(tel.get("snd"), (int, float)):
                    raise ValueError
                self.tel_lat.append(now_ms() - tel["snd"])
            except ValueError:
                self.chk.fail(f"bad telemetry prefix {p[:sc][:80]!r}")
        else:
            self.chk.fail("video frame without telemetry prefix")
        es = p[sc:]
        # 3-byte start code check: every 00 00 01 must be the tail of 00 00 00 01.
        i = es.find(b"\x00\x00\x01")
        while i >= 0:
            if i == 0 or es[i - 1] != 0:
                self.chk.fail(f"3-byte start code in frame {self.video_frames}")
                break
            i = es.find(b"\x00\x00\x01", i + 3)
        if self.dump:
            self.dump.write(es)
        nals = split_nals(es)
        hevc = self.codec == "hevc"
        types = [((n[0] >> 1) & 0x3F) if hevc else (n[0] & 0x1F) for n in nals if n]
        vcl = [(t, n) for t, n in zip(types, [n for n in nals if n])
               if (t <= 31 if hevc else 1 <= t <= 5)]
        if not vcl:
            self.chk.fail(f"frame {self.video_frames} has no VCL NAL (types {types})")
            return
        first_flags = [bool(n[2] & 0x80) if hevc else bool(n[1] & 0x80) for _, n in vcl]
        if not first_flags[0] or sum(first_flags) != 1:
            self.chk.fail(f"frame {self.video_frames} is not exactly one picture "
                          f"(first-slice flags {first_flags[:8]}...)")
        idr_types = IDR_HEVC if hevc else IDR_H264
        is_idr = any(t in idr_types for t, _ in vcl)
        if is_idr:
            self.idrs += 1
            need = [32, 33, 34] if hevc else [7, 8]
            first_vcl = next(i for i, t in enumerate(types) if (t <= 31 if hevc else 1 <= t <= 5))
            before = types[:first_vcl]
            if not all(x in before for x in need):
                self.chk.fail(f"IDR frame {self.video_frames} lacks parameter sets before slice: {types[:8]}")
            elif hevc and not (before.index(32) < before.index(33) < before.index(34)):
                self.chk.fail(f"HEVC param sets out of order {before}")
        if self.expect_idr:
            if is_idr:
                lat = (time.monotonic() - self.expect_since) * 1000 if self.expect_since else None
                log(f"IDR after {self.expect_idr}: ok"
                    + (f" ({lat:.0f} ms, {self.non_idr_while_expecting} older frames in flight)" if lat else "")
                    + f", NAL types {types[:6]}")
                if lat is not None:
                    self.idr_latencies.append((self.expect_idr, lat, self.non_idr_while_expecting))
                self.expect_idr = None
            else:
                if self.expect_idr == "session start":
                    self.chk.fail("first video frame of the session is not an IDR")
                    self.expect_idr = None
                else:
                    self.non_idr_while_expecting += 1
                    if time.monotonic() - self.expect_since > 1.0:
                        self.chk.fail(f"no IDR within 1 s after {self.expect_idr}")
                        self.expect_idr = None

    def run(self):
        c = self.c
        self.hello()
        for f in (self.pinger, self.script, self.watchdog):
            threading.Thread(target=f, daemon=True).start()
        buf = bytearray()
        try:
            while self.alive:
                d = c.recv(1 << 20)
                if not d:
                    break
                self.last_rx = time.monotonic()
                buf += d
                while len(buf) >= 4:
                    n = struct.unpack(">I", buf[:4])[0]
                    if len(buf) < 4 + n:
                        break
                    p = bytes(buf[4:4 + n])
                    del buf[:4 + n]
                    if n == 0:
                        self.chk.fail("zero-length frame")
                        continue
                    if is_json_frame(p):
                        self.on_control(p)
                    else:
                        if p[:1] == b"{" and len(p) < 32768 and b"\x00\x00\x00\x01" not in p:
                            self.chk.fail("control-looking frame with NUL (would be misrouted)")
                        self.on_video(p)
        except OSError:
            pass
        self.alive = False
        if self.dump:
            self.dump.close()

    def report(self):
        el = time.monotonic() - self.t0
        vel = time.monotonic() - self.first_video_ms if self.first_video_ms else 0
        chk = self.chk
        if self.welcomes != self.hellos_sent:
            chk.fail(f"welcomes {self.welcomes} != hellos {self.hellos_sent}")
        if self.counts["streamConfig"] == 0:
            chk.fail("no streamConfig")
        if not self.cursor_img:
            chk.fail("no cursorImg")
        if self.cursor_tcp + self.cursor_udp == 0:
            chk.fail("no cursor updates")
        if self.sender_pings == 0:
            chk.fail("sender never pinged")
        if self.video_frames == 0:
            chk.fail("no video")
        if self.expect_idr and self.expect_idr != "session start":
            chk.fail(f"still waiting for IDR after {self.expect_idr}")
        if self.a.expect_codec and self.codec != self.a.expect_codec:
            chk.fail(f"codec {self.codec}, expected {self.a.expect_codec}")
        rtt = sorted(self.rtts)
        lat = sorted(self.tel_lat)
        print("\n===== mock-receiver summary =====")
        print(f"session           {el:.1f} s")
        print(f"stream            {self.codec} {self.stream}")
        print(f"video frames      {self.video_frames} ({self.video_frames / vel if vel else 0:.1f}/s), "
              f"{self.video_bytes * 8 / 1e6 / vel if vel else 0:.2f} Mbit/s, IDRs {self.idrs}")
        for why, ms, n in self.idr_latencies:
            print(f"IDR after {why:<12} {ms:.0f} ms ({n} older frames in flight)")
        print(f"telemetry snd->rx median {lat[len(lat) // 2] if lat else '-'} ms, "
              f"max {lat[-1] if lat else '-'} ms")
        print(f"pongs             {len(self.rtts)} (unanswered {len(self.pings_out)}), RTT median "
              f"{rtt[len(rtt) // 2]:.1f} ms" if rtt else "pongs             none")
        print(f"sender pings      {self.sender_pings}")
        print(f"hellos/welcomes   {self.hellos_sent}/{self.welcomes}")
        print(f"cursor            tcp {self.cursor_tcp}, udp {self.cursor_udp}, highest s {self.cursor_s}, "
              f"stale/dup {self.cursor_dupes}, acked {self.udp_acked}")
        print("sender messages   " + ", ".join(f"{k}={v}" for k, v in sorted(self.counts.items())))
        print(f"RESULT: {'PASS' if not chk.fails else f'FAIL ({len(chk.fails)} problems)'}")
        for f in chk.fails[:20]:
            print("  -", f)


def main():
    p = argparse.ArgumentParser(description="Validating mock OpenDisplay receiver (pv 3).")
    p.add_argument("--port", type=int, default=19000)
    p.add_argument("--kf-at", type=float, default=3)
    p.add_argument("--rotate-at", type=float, default=0, help="re-hello rotated at N s (0 = never)")
    p.add_argument("--udp-port", type=int, default=0, help="offer a UDP cursor port (0 = none)")
    p.add_argument("--no-hevc", action="store_true", help="offer only h264")
    p.add_argument("--expect-codec", choices=["h264", "hevc"])
    p.add_argument("--dump", help="write the received elementary stream here")
    a = p.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(1)
    log(f"listening on 127.0.0.1:{a.port}")
    conn, addr = srv.accept()
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    log(f"sender connected from {addr}")
    chk = Check()
    s = Session(conn, a, chk)
    if a.udp_port:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind(("127.0.0.1", a.udp_port))
        u.settimeout(0.5)

        def udp_loop():
            while s.alive:
                try:
                    d, _ = u.recvfrom(2048)
                except socket.timeout:
                    continue
                except OSError:
                    break
                s.on_udp(d)
        threading.Thread(target=udp_loop, daemon=True).start()
    s.run()
    srv.close()
    s.report()
    sys.exit(0 if not chk.fails else 1)


if __name__ == "__main__":
    main()
