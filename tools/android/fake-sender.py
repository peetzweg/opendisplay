#!/usr/bin/env python3
"""Scripted OpenDisplay sender (PROTOCOL.md, pv 3) for testing receivers.

Dials a receiver over TCP, waits for `hello`, answers `welcome`, announces
`streamConfig`, and streams an ffmpeg test pattern (H.264 or HEVC Annex B,
one access unit per wire frame, 4-byte start codes, parameter sets on every
IDR, telemetry prefix). Also drives pings/pongs, a cursor sprite and a
circling cursor (TCP, optionally mirrored over the UDP side channel), and
logs everything the receiver sends.

Keyframe recovery (`kf`) and stream changes (re-`hello`, simulated sleep)
restart the ffmpeg encoder: its first output is always an IDR preceded by
its parameter sets, and nothing from the old encoder is sent after the
restart is requested.

Stdlib only, plus ffmpeg (libx264 / libx265) via subprocess.
"""

import argparse
import base64
import json
import math
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import zlib
from collections import Counter

PV = 3
JSON_MAX = 32768


def now_ms():
    return int(time.time() * 1000)


def log(*a):
    print(f"[{time.strftime('%H:%M:%S')}.{int(time.time() * 1000) % 1000:03d}]", *a, flush=True)


# --------------------------------------------------------------------------
# PNG cursor sprite (pure python)
# --------------------------------------------------------------------------

def _png_chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def arrow_png(w=24, h=36):
    """Classic arrow: black outline, white fill, transparent elsewhere. RGBA."""
    # Arrow polygon in sprite pixels, hotspot at (0,0).
    poly = [(0, 0), (0, 28), (7, 22), (12, 34), (16, 32), (11, 21), (20, 21)]

    def inside(px, py):
        n, c = len(poly), False
        j = n - 1
        for i in range(n):
            xi, yi = poly[i]
            xj, yj = poly[j]
            if (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi:
                c = not c
            j = i
        return c

    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: none
        for x in range(w):
            cx, cy = x + 0.5, y + 0.5
            if inside(cx, cy):
                edge = any(not inside(cx + dx, cy + dy)
                           for dx, dy in ((-1.2, 0), (1.2, 0), (0, -1.2), (0, 1.2)))
                raw += bytes((0, 0, 0, 255)) if edge else bytes((255, 255, 255, 255))
            else:
                raw += bytes((0, 0, 0, 0))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", ihdr)
            + _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + _png_chunk(b"IEND", b""))


# --------------------------------------------------------------------------
# Annex B access-unit splitter
# --------------------------------------------------------------------------

class AUSplitter:
    """Feeds raw Annex B bytes, yields complete access units as lists of NAL
    payloads (no start codes). AU boundaries follow H.264 7.4.1.2.3 / HEVC
    7.4.2.4.4: a new AU begins at an AUD / parameter set / prefix SEI that
    follows a VCL NAL, or at a VCL NAL that is the first slice of a picture.
    `flush()` closes the pending AU when the producer is known to be idle
    (ffmpeg writes one packet = one AU per write burst)."""

    def __init__(self, codec):
        self.hevc = codec == "hevc"
        self.buf = bytearray()
        self.cur = []          # NALs of the AU being built
        self.cur_has_vcl = False
        self.prefix = []       # non-VCL NALs seen after a VCL: belong to the next AU
        self.started_ms = None

    def nal_type(self, nal):
        return (nal[0] >> 1) & 0x3F if self.hevc else nal[0] & 0x1F

    def is_vcl(self, t):
        return t <= 31 if self.hevc else 1 <= t <= 5

    def first_slice(self, nal):
        # H.264: first_mb_in_slice ue(v)==0 <=> first bit after 1-byte header is 1.
        # HEVC: first_slice_segment_in_pic_flag is the first bit after 2-byte header.
        if self.hevc:
            return len(nal) > 2 and bool(nal[2] & 0x80)
        return len(nal) > 1 and bool(nal[1] & 0x80)

    def opens_au(self, t):
        if self.hevc:
            return t in (32, 33, 34, 35, 39) or 41 <= t <= 44 or 48 <= t <= 55
        return t in (6, 7, 8, 9) or 14 <= t <= 18

    def feed(self, data):
        if self.started_ms is None:
            self.started_ms = now_ms()
        self.buf += data
        out = []
        # Extract every NAL that is followed by another start code.
        while True:
            s = self.buf.find(b"\x00\x00\x01")
            if s < 0:
                break
            e = self.buf.find(b"\x00\x00\x01", s + 3)
            if e < 0:
                if s > 0:
                    del self.buf[:s]
                break
            nal = bytes(self.buf[s + 3:e]).rstrip(b"\x00")
            del self.buf[:e]
            if nal:
                out += self._nal(nal)
        return out

    def flush(self):
        """Producer idle: the trailing bytes are a complete NAL; close the AU."""
        out = []
        s = self.buf.find(b"\x00\x00\x01")
        if s >= 0:
            nal = bytes(self.buf[s + 3:]).rstrip(b"\x00")
            self.buf.clear()
            if nal:
                out += self._nal(nal)
        if self.cur_has_vcl:
            out.append((self.cur, self.started_ms))
            self.cur, self.cur_has_vcl = list(self.prefix), False
            self.prefix = []
            self.started_ms = None
        return out

    def _nal(self, nal):
        t = self.nal_type(nal)
        out = []
        if self.is_vcl(t):
            if self.cur_has_vcl and self.first_slice(nal):
                out.append((self.cur, self.started_ms))
                self.cur, self.cur_has_vcl = list(self.prefix), False
                self.started_ms = now_ms()
            elif self.prefix:
                self.cur += self.prefix
            self.prefix = []
            self.cur.append(nal)
            self.cur_has_vcl = True
        elif self.cur_has_vcl and self.opens_au(t):
            self.prefix.append(nal)
        elif self.cur_has_vcl and self.prefix:
            self.prefix.append(nal)
        else:
            self.cur.append(nal)  # prefix of the current AU, or a suffix NAL
        return out


def is_idr(codec, nals):
    if codec == "hevc":
        return any(((n[0] >> 1) & 0x3F) in (19, 20, 21) for n in nals)
    return any((n[0] & 0x1F) == 5 for n in nals)


# --------------------------------------------------------------------------
# Encoder (ffmpeg subprocess), restartable
# --------------------------------------------------------------------------

class Encoder:
    def __init__(self, sender, ffmpeg, bitrate, verbose):
        self.s = sender
        self.ffmpeg = ffmpeg
        self.bitrate = bitrate
        self.verbose = verbose
        self.lock = threading.Lock()
        self.proc = None
        self.gen = 0
        self.restarts = 0

    def cmd(self, codec, w, h, fps):
        src = f"testsrc2=size={w}x{h}:rate={fps},realtime"
        base = [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
                "-f", "lavfi", "-i", src, "-pix_fmt", "yuv420p"]
        rate = ["-b:v", self.bitrate, "-maxrate", self.bitrate, "-bufsize", self.bitrate]
        if codec == "hevc":
            enc = ["-c:v", "libx265", "-preset", "ultrafast", "-tune", "zerolatency", *rate,
                   "-x265-params",
                   "repeat-headers=1:keyint=600:min-keyint=600:scenecut=0:bframes=0:"
                   "open-gop=0:log-level=error",
                   "-f", "hevc"]
        else:
            enc = ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                   "-profile:v", "main", "-bf", "0", "-g", "600", "-keyint_min", "600",
                   "-sc_threshold", "0", *rate,
                   "-x264-params", "repeat-headers=1", "-f", "h264"]
        return base + enc + ["-flush_packets", "1", "pipe:1"]

    def start(self, codec, w, h, fps):
        """(Re)start the encoder. Frames of earlier generations are dropped."""
        with self.lock:
            self.gen += 1  # first, so the old pump sees itself superseded at EOF
            gen = self.gen
            self._kill()
            cmd = self.cmd(codec, w, h, fps)
            if self.verbose:
                log("ffmpeg:", " ".join(cmd))
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                         stderr=None, bufsize=0)
            self.restarts += 1
            proc = self.proc
        threading.Thread(target=self._pump, args=(proc, gen, codec), daemon=True).start()

    def stop(self):
        with self.lock:
            self.gen += 1
            self._kill()

    def _kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        self.proc = None

    def current(self, gen):
        return gen == self.gen

    def _pump(self, proc, gen, codec):
        try:
            self._pump_loop(proc, gen, codec)
        finally:
            try:
                proc.stdout.close()
            except OSError:
                pass

    def _pump_loop(self, proc, gen, codec):
        sp = AUSplitter(codec)
        fd = proc.stdout.fileno()
        while self.current(gen):
            r, _, _ = select.select([fd], [], [], 0.004)
            if not r:
                aus = sp.flush()  # idle: ffmpeg finished writing its packet
            else:
                try:
                    data = os.read(fd, 1 << 20)
                except OSError:
                    data = b""
                if not data:
                    if self.current(gen):
                        log("ffmpeg exited unexpectedly (rc=%s)" % proc.poll())
                        self.s.encoder_died(gen)
                    return
                aus = sp.feed(data)
            for nals, cap in aus:
                if not self.current(gen):
                    return
                self.s.send_video(gen, nals, cap)


# --------------------------------------------------------------------------
# Sender
# --------------------------------------------------------------------------

class Sender:
    def __init__(self, args):
        self.a = args
        self.sock = None
        self.wlock = threading.Lock()
        self.alive = True
        self.dropped = False
        self.t0 = time.monotonic()
        self.counts = Counter()
        self.hello = None
        self.hello_count = 0
        self.hello_problems = []
        self.codec = None
        self.w = self.h = 0
        self.fps = args.fps
        self.paused = False
        self.need_idr = False
        self.frames_sent = 0
        self.idr_sent = 0
        self.bytes_sent = 0
        self.kf_requests = 0
        self.pings_sent = 0
        self.pongs_sent = 0
        self.cursor_tcp = 0
        self.cursor_udp = 0
        self.cursor_seq = 0
        self.udp = None
        self.udp_addr = None
        self.udp_started = None
        self.cursor_acked = False
        self.rotations = 0
        self.frames_since_tick = 0
        self.restart_lock = threading.Lock()
        self.enc = Encoder(self, args.ffmpeg, args.bitrate, args.verbose)
        self.hello_evt = threading.Event()

    # ---- wire ----
    def write(self, payload):
        hdr = struct.pack(">I", len(payload))
        with self.wlock:
            if not self.alive:
                return False
            try:
                self.sock.sendall(hdr + payload)
                self.bytes_sent += 4 + len(payload)
                return True
            except OSError as e:
                if self.alive:
                    log("send failed:", e)
                    self.dropped = True
                    self.alive = False
                return False

    def send_ctl(self, obj):
        p = json.dumps(obj, separators=(",", ":")).encode()
        assert len(p) < JSON_MAX and p[:1] == b"{" and b"\x00" not in p, "demux rule violated"
        return self.write(p)

    def send_video(self, gen, nals, cap):
        if self.paused or not self.alive:
            return
        with self.restart_lock:
            if not self.enc.current(gen):
                return
            idr = is_idr(self.codec, nals)
            if self.need_idr and not idr:
                return  # cannot happen with a fresh encoder; guard anyway
            self.need_idr = False
            body = b"".join(b"\x00\x00\x00\x01" + n for n in nals)
            tel = json.dumps({"cap": cap or now_ms(), "snd": now_ms()},
                             separators=(",", ":")).encode()
            if self.write(tel + body):
                self.frames_sent += 1
                self.frames_since_tick += 1
                if idr:
                    self.idr_sent += 1
                    if self.a.verbose or self.idr_sent <= 20:
                        log(f"IDR sent ({len(body)} B, {len(nals)} NALs, frame #{self.frames_sent})")

    def encoder_died(self, gen):
        if self.alive and not self.paused and self.enc.current(gen):
            threading.Thread(target=self.restart_encoder, args=("encoder died",), daemon=True).start()

    # ---- stream setup ----
    def choose_stream(self, hello):
        caps = hello.get("videoCaps") if isinstance(hello.get("videoCaps"), list) else []
        caps = [c for c in caps if isinstance(c, dict)]
        offered = {str(c.get("codec", "")).lower() for c in caps}
        if self.a.codec == "auto":
            codec = "hevc" if "hevc" in offered else "h264"
        else:
            codec = self.a.codec
            if codec == "hevc" and "hevc" not in offered:
                log("WARNING: --codec hevc but receiver did not offer hevc (spec forbids this); sending anyway")
        if self.a.size:
            w, h = (int(v) for v in self.a.size.lower().split("x"))
        else:
            panel = hello.get("panel") if self.panel_ok(hello.get("panel")) else None
            if panel:
                w, h = panel["pixelsWide"], panel["pixelsHigh"]
            else:
                w, h = int(hello.get("pixelsWide", 1920)), int(hello.get("pixelsHigh", 1080))
        fps = self.a.fps
        entries = [c for c in caps if str(c.get("codec", "")).lower() == codec]
        if entries:
            c = entries[0]  # alternative envelopes: use the first one
            mw, mh = c.get("maxWidth"), c.get("maxHeight")
            f = 1.0
            if isinstance(mw, (int, float)) and w > mw:
                f = min(f, mw / w)
            if isinstance(mh, (int, float)) and h > mh:
                f = min(f, mh / h)
            if f < 1.0:
                w, h = int(w * f), int(h * f)
            mfr = c.get("maxFrameRate")
            if isinstance(mfr, (int, float)) and fps > mfr:
                fps = int(mfr)
            mpps = c.get("maxPixelsPerSecond")
            if isinstance(mpps, (int, float)) and w * h * fps > mpps:
                f = math.sqrt(mpps / (w * h * fps))
                w, h = int(w * f), int(h * f)
        if codec == "h264":
            mw, mh = hello.get("maxEncodeWide"), hello.get("maxEncodeHigh")
            f = 1.0
            if isinstance(mw, (int, float)) and w > mw:
                f = min(f, mw / w)
            if isinstance(mh, (int, float)) and h > mh:
                f = min(f, mh / h)
            if f < 1.0:
                w, h = int(w * f), int(h * f)
        w, h = max(2, w - w % 2), max(2, h - h % 2)
        return codec, w, h, fps

    @staticmethod
    def panel_ok(p):
        if not isinstance(p, dict):
            return False
        pw, ph, sc = p.get("pixelsWide"), p.get("pixelsHigh"), p.get("scale")
        ints = lambda v: isinstance(v, int) and not isinstance(v, bool) and v >= 2
        if not (ints(pw) and ints(ph)):
            return False
        if not (isinstance(sc, (int, float)) and not isinstance(sc, bool) and math.isfinite(sc) and sc > 0):
            return False
        pts = (p.get("pointsWide"), p.get("pointsHigh"))
        return pts == (None, None) or (ints(pts[0]) and ints(pts[1]))

    def validate_hello(self, h):
        probs = []
        if not self.panel_ok(h.get("panel")):
            probs.append("panel missing or malformed (need int pixelsWide/High >= 2, scale > 0)")
        if h.get("pv") != PV:
            probs.append(f"pv is {h.get('pv')!r}, expected {PV}")
        if not h.get("id"):
            probs.append("id missing")
        caps = h.get("videoCaps")
        if not isinstance(caps, list) or not any(
                isinstance(c, dict) and str(c.get("codec", "")).lower() == "h264" for c in caps):
            probs.append("videoCaps missing or has no h264 entry")
        extras = []
        for k in ("cursorPort", "displayMaxFrameRate", "device", "addrs", "power",
                  "maxEncodeWide", "maxEncodeHigh"):
            if k in h:
                extras.append(f"{k}={h[k]}")
        if isinstance(caps, list):
            for c in caps:
                if isinstance(c, dict) and str(c.get("codec", "")).lower() == "hevc":
                    extras.append(f"hevc cap {json.dumps(c)}")
        return probs, extras

    def restart_encoder(self, why):
        with self.restart_lock:
            if not self.alive:
                return
            log(f"encoder restart ({why}) -> {self.codec} {self.w}x{self.h}@{self.fps}")
            self.need_idr = True
            self.enc.start(self.codec, self.w, self.h, self.fps)

    def on_hello(self, msg):
        self.hello_count += 1
        first = self.hello is None
        self.send_ctl({"type": "welcome", "pv": PV, "min": 1})
        log(("hello" if first else f"hello #{self.hello_count} (re-hello)") + ":\n"
            + json.dumps(msg, indent=2))
        probs, extras = self.validate_hello(msg)
        for p in probs:
            log("HELLO PROBLEM:", p)
            self.hello_problems.append(p)
        log("hello extras:", ", ".join(extras) if extras else "(none)")
        old = (self.codec, self.w, self.h, self.fps)
        self.hello = msg
        codec, w, h, fps = self.choose_stream(msg)
        if first or (codec, w, h, fps) != old:
            if not first:
                self.rotations += 1
                log(f"stream change {old[1]}x{old[2]} -> {w}x{h}")
            self.codec, self.w, self.h, self.fps = codec, w, h, fps
            self.send_ctl({"type": "streamConfig", "codec": codec, "width": w,
                           "height": h, "framesPerSecond": fps})
            log(f"streamConfig: {codec} {w}x{h}@{fps}")
            if not self.paused:
                self.restart_encoder("hello" if first else "re-hello")
        else:
            log("re-hello with unchanged stream: no restart")
        if first:
            self.setup_udp(msg)
            self.hello_evt.set()

    def setup_udp(self, msg):
        port = msg.get("cursorPort")
        if self.a.udp_cursor and isinstance(port, int):
            self.udp = socket.socket(socket.AF_INET6 if ":" in self.a.host else socket.AF_INET,
                                     socket.SOCK_DGRAM)
            self.udp_addr = (self.a.host, port)
            self.udp_started = time.monotonic()
            log(f"UDP cursor side channel -> {self.a.host}:{port} (mirroring on TCP until cursorAck)")
        elif self.a.udp_cursor:
            log("--udp-cursor: hello has no cursorPort, cursor stays on TCP")

    # ---- loops ----
    def reader(self):
        buf = bytearray()
        try:
            while self.alive:
                data = self.sock.recv(65536)
                if not data:
                    if self.alive:
                        log("receiver closed the connection")
                        self.dropped = True
                    break
                buf += data
                while len(buf) >= 4:
                    n = struct.unpack(">I", buf[:4])[0]
                    if n == 0 or n >= (1 << 20):
                        log(f"PROTOCOL ERROR: frame length {n}; stop reading")
                        self.dropped = True
                        self.alive = False
                        return
                    if len(buf) < 4 + n:
                        break
                    payload = bytes(buf[4:4 + n])
                    del buf[:4 + n]
                    self.on_frame(payload)
        except OSError as e:
            if self.alive:
                log("recv failed:", e)
                self.dropped = True
        finally:
            self.alive = False
            self.hello_evt.set()

    def on_frame(self, payload):
        try:
            msg = json.loads(payload)
            t = msg.get("type") if isinstance(msg, dict) else None
        except ValueError:
            msg, t = None, None
        if not isinstance(t, str):
            log(f"unparseable control payload ({len(payload)} B), ignored")
            self.counts["<unparseable>"] += 1
            return
        self.counts[t] += 1
        if self.hello is None and t != "hello":
            log(f"FATAL: first receiver message is {t!r}, not hello: {payload[:200]!r}")
            self.hello_problems.append(f"first message was {t}")
            self.alive = False
            self.hello_evt.set()
            return
        if t == "hello":
            self.on_hello(msg)
        elif t == "ping":
            if self.send_ctl({"type": "pong", "t": msg.get("t"), "mt": now_ms()}):
                self.pongs_sent += 1
            if self.a.verbose:
                log("ping", msg)
        elif t == "kf":
            self.kf_requests += 1
            log(f"kf request #{self.kf_requests}")
            if not self.paused:
                threading.Thread(target=self.restart_encoder, args=("kf",), daemon=True).start()
        elif t in ("touch", "scroll", "pencil", "proximity", "stats"):
            log(f"{t}: {json.dumps(msg)}")
        elif t == "cursorAck":
            if not self.cursor_acked:
                log(f"cursorAck received after {time.monotonic() - (self.udp_started or self.t0):.2f}s"
                    " -> cursor now UDP only")
            self.cursor_acked = True
        elif t in ("sleeping", "closing"):
            log(f"receiver says {t}; it will close the connection")
        elif self.counts[t] == 1:
            log(f"unknown type {t!r} (logged once): {json.dumps(msg)}")

    def pinger(self):
        while self.alive:
            time.sleep(2)
            if not self.alive:
                break
            if self.send_ctl({"type": "ping", "encDrops": 0, "netDrops": 0, "pending": 0,
                              "capFps": round(self.frames_since_tick / 2.0, 1)}):
                self.pings_sent += 1
            self.frames_since_tick = 0

    def cursor_loop(self):
        png = arrow_png()
        assert len(png) < 24000
        self.send_ctl({"type": "cursorImg", "nw": 0.02, "nh": 0.03, "ax": 0, "ay": 0,
                       "png": base64.b64encode(png).decode()})
        log(f"cursorImg sent ({len(png)} B PNG)")
        period = 1 / 60
        nxt = time.monotonic()
        while self.alive:
            nxt += period
            d = nxt - time.monotonic()
            if d > 0:
                time.sleep(d)
            else:
                nxt = time.monotonic()
            ph = (time.monotonic() - self.t0) * 0.5 * 2 * math.pi  # one lap per 2 s
            self.cursor_seq += 1
            m = {"type": "cursor", "x": round(0.5 + 0.3 * math.cos(ph), 4),
                 "y": round(0.5 + 0.3 * math.sin(ph), 4), "v": 1, "s": self.cursor_seq}
            use_udp = self.udp is not None
            if use_udp and not self.cursor_acked and time.monotonic() - self.udp_started > 3:
                log("no cursorAck within 3 s: dropping UDP flow, cursor stays on TCP")
                self.udp.close()
                self.udp = None
                use_udp = False
            if use_udp:
                try:
                    self.udp.sendto(json.dumps(m, separators=(",", ":")).encode(), self.udp_addr)
                    self.cursor_udp += 1
                except OSError as e:
                    log("UDP send failed:", e)
            if not use_udp or not self.cursor_acked:
                if self.send_ctl(m):
                    self.cursor_tcp += 1

    def sleep_test(self, at):
        time.sleep(max(0, at - (time.monotonic() - self.t0)))
        if not self.alive:
            return
        log("sending {type: sleeping}, pausing video for 3 s")
        self.send_ctl({"type": "sleeping"})
        self.paused = True
        self.enc.stop()
        time.sleep(3)
        if not self.alive:
            return
        self.paused = False
        self.send_ctl({"type": "streamConfig", "codec": self.codec, "width": self.w,
                       "height": self.h, "framesPerSecond": self.fps})
        self.restart_encoder("resume after sleeping")

    def run(self):
        a = self.a
        log(f"dialing {a.host}:{a.port}")
        try:
            self.sock = socket.create_connection((a.host, a.port), timeout=5)
        except OSError as e:
            log("connect failed:", e)
            return 2
        self.sock.settimeout(None)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=self.reader, daemon=True).start()
        if not self.hello_evt.wait(a.hello_timeout) or self.hello is None:
            log(f"FAIL: no hello within {a.hello_timeout}s")
            self.alive = False
            self.shutdown()
            return 2
        threading.Thread(target=self.pinger, daemon=True).start()
        threading.Thread(target=self.cursor_loop, daemon=True).start()
        if a.send_sleeping_at is not None:
            threading.Thread(target=self.sleep_test, args=(a.send_sleeping_at,), daemon=True).start()
        deadline = self.t0 + a.duration if a.duration else None
        last_report = time.monotonic()
        last_frames = 0
        try:
            while self.alive and (deadline is None or time.monotonic() < deadline):
                time.sleep(0.1)
                if time.monotonic() - last_report >= 5:
                    el = time.monotonic() - last_report
                    log(f"video {(self.frames_sent - last_frames) / el:.1f} fps, "
                        f"{self.frames_sent} frames, {self.bytes_sent * 8 / 1e6 / (time.monotonic() - self.t0):.1f} Mbit/s avg")
                    last_report, last_frames = time.monotonic(), self.frames_sent
        except KeyboardInterrupt:
            log("interrupted")
        early = self.dropped
        self.shutdown()
        return self.summary(early)

    def shutdown(self):
        self.alive = False
        self.enc.stop()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

    def summary(self, early):
        el = time.monotonic() - self.t0
        print("\n===== fake-sender summary =====")
        print(f"duration          {el:.1f} s")
        print(f"stream            {self.codec} {self.w}x{self.h}@{self.fps}")
        print(f"frames sent       {self.frames_sent} ({self.frames_sent / el:.1f}/s), IDRs {self.idr_sent}")
        print(f"bytes sent        {self.bytes_sent} ({self.bytes_sent * 8 / 1e6 / el:.2f} Mbit/s)")
        print(f"encoder starts    {self.enc.restarts}")
        print(f"kf requests       {self.kf_requests}")
        print(f"hellos            {self.hello_count} (stream changes {self.rotations})")
        print(f"pings sent        {self.pings_sent}; pongs sent {self.pongs_sent} "
              f"(receiver pings {self.counts['ping']})")
        print(f"cursor            tcp {self.cursor_tcp}, udp {self.cursor_udp}, "
              f"last s {self.cursor_seq}, cursorAck {'yes' if self.cursor_acked else 'no'}")
        print("receiver messages " + (", ".join(f"{k}={v}" for k, v in sorted(self.counts.items())) or "(none)"))
        rc = 0
        if self.hello is None:
            print("RESULT: FAIL (no hello)")
            rc = 2
        elif early:
            print("RESULT: FAIL (connection dropped early)")
            rc = 3
        elif self.hello_problems:
            print("RESULT: FAIL (hello problems: " + "; ".join(self.hello_problems) + ")")
            rc = 4
        elif self.a.rotate_test and self.rotations == 0:
            print("RESULT: FAIL (--rotate-test: no re-hello with a new size arrived)")
            rc = 5
        else:
            print("RESULT: OK")
        return rc


def main():
    p = argparse.ArgumentParser(description="Scripted OpenDisplay sender for receiver testing (pv 3).")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=9000)
    p.add_argument("--codec", choices=["auto", "h264", "hevc"], default="auto",
                   help="auto = hevc if the receiver offers it in videoCaps")
    p.add_argument("--size", help="stream size WxH (default: hello.panel, clamped by videoCaps)")
    p.add_argument("--fps", type=int, default=60)
    p.add_argument("--bitrate", default="8M", help="ffmpeg bitrate (default 8M)")
    p.add_argument("--duration", type=float, default=0, help="seconds to run (0 = until Ctrl-C / drop)")
    p.add_argument("--send-sleeping-at", type=float, metavar="N",
                   help="at N s send {type: sleeping}, pause video 3 s, then resume with an IDR")
    p.add_argument("--rotate-test", action="store_true",
                   help="expect a re-hello with new dimensions; exit nonzero if none arrives")
    p.add_argument("--udp-cursor", action="store_true",
                   help="also send cursor datagrams to hello.cursorPort")
    p.add_argument("--hello-timeout", type=float, default=10)
    p.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args()
    if not os.path.exists(a.ffmpeg):
        sys.exit(f"ffmpeg not found at {a.ffmpeg}")
    sys.exit(Sender(a).run())


if __name__ == "__main__":
    main()
