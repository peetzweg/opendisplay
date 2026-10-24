// Transport spike: replay a video frame-size trace over TCP, UDP, or QUIC
// between two Macs and measure what the receiver would see.
//
//   nettest trace <out.txt> <width> <height> <fps> <mbps> [codec=hevc|h264] [seconds=20]
//        hardware-encode synthetic scrolling text with content changes every 3 s
//        and write one frame size per line (first line: fps)
//   nettest recv [port=9100]
//   nettest send <host> <mode> <trace.txt> [seconds=30] [label] [key=value...]
//        modes: tcp | quic1 (one QUIC stream) | quicN (a stream per frame)
//               udp | udpnack | qdgram | qdgramnack
//        options: pace=<Mbps> (datagram modes, 0 = burst), inflight=<frames> (default 3)
//
// Ports: base (TCP, UDP), +1 QUIC streams, +2 clock sync (UDP), +3 control (TCP),
// +4 QUIC datagrams. The receiver prints one JSON summary line per run.
import Foundation
import Network
import Security
import CoreGraphics
import CoreText
import VideoToolbox

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_REALTIME) }
func port(_ p: Int) -> NWEndpoint.Port { NWEndpoint.Port(rawValue: UInt16(p))! }

extension Data {
    mutating func put<T: FixedWidthInteger>(_ v: T) { var b = v.bigEndian; append(Data(bytes: &b, count: MemoryLayout<T>.size)) }
    func get<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T {
        var v: T = 0
        for i in 0..<MemoryLayout<T>.size { v = v << 8 | T(self[startIndex + o + i]) }
        return v
    }
}

// MARK: - QUIC TLS (throwaway self-signed identity, verification disabled)

// Import into a throwaway file keychain: over ssh the login keychain is locked
// and SecPKCS12Import fails with errSecInteractionNotAllowed.
let serverIdentity: SecIdentity = {
    let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let p12 = try! Data(contentsOf: dir.appendingPathComponent("nettest.p12"))
    let kcPath = NSTemporaryDirectory() + "nettest-\(getpid()).keychain"   // absolute, unique
    var kc: SecKeychain?
    let kst = SecKeychainCreate(kcPath, 7, "nettest", false, nil, &kc)
    precondition(kc != nil, "keychain create failed \(kst)")
    var items: CFArray?
    let st = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: "nettest",
                                             kSecImportExportKeychain: kc!] as CFDictionary, &items)
    precondition(st == errSecSuccess, "p12 import failed \(st)")
    return (items as! [[String: Any]])[0][kSecImportItemIdentity as String] as! SecIdentity
}()

let alpn = "odspike"
func quicOptions(server: Bool, datagram: Bool) -> NWProtocolQUIC.Options {
    let o = NWProtocolQUIC.Options(alpn: [alpn])
    o.idleTimeout = 60_000
    o.initialMaxStreamsBidirectional = 100_000
    o.initialMaxStreamsUnidirectional = 100_000
    o.initialMaxData = 64 << 20
    o.initialMaxStreamDataBidirectionalRemote = 16 << 20
    o.initialMaxStreamDataBidirectionalLocal = 16 << 20
    o.initialMaxStreamDataUnidirectional = 16 << 20
    if datagram { o.isDatagram = true; o.maxDatagramFrameSize = 65_535 }
    let sec = o.securityProtocolOptions
    if server {
        sec_protocol_options_set_local_identity(sec, sec_identity_create(serverIdentity)!)
    } else {
        sec_protocol_options_set_verify_block(sec, { _, _, done in done(true) }, DispatchQueue(label: "verify"))   // main is blocked in waits
    }
    return o
}

// MARK: - trace

func makeTrace() {
    let out = args[2], w = Int(args[3])!, h = Int(args[4])!, fps = Int(args[5])!, mbps = Int(args[6])!
    let hevc = (args.count > 7 ? args[7] : "hevc") == "hevc"
    let seconds = args.count > 8 ? Int(args[8])! : 20
    var session: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
    precondition(VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
        codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: spec,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
        compressionSessionOut: &session) == noErr)
    let s = session!
    // Same settings as MacSender.setupEncoder.
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: mbps * 1_000_000 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
    // A tall page of text and colour blocks; each "document" differs.
    func page(_ seed: Int) -> CGImage {
        let ph = h * 3
        let ctx = CGContext(data: nil, width: w, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: ph))
        var rng = UInt64(seed * 7919 + 1)
        func rnd() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        let words = "the quick brown fox jumps over a lazy dog while OpenDisplay streams frames 0123456789 {}[]();".split(separator: " ")
        let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(h) / 70, nil)
        var y = CGFloat(ph) - 40
        while y > 0 {
            if rnd() < 0.08 {
                ctx.setFillColor(CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1))
                let bh = CGFloat(h) / 8 * CGFloat(1 + rnd())
                ctx.fill(CGRect(x: CGFloat(w) * 0.1, y: y - bh, width: CGFloat(w) * CGFloat(0.3 + rnd() * 0.5), height: bh))
                y -= bh + 20; continue
            }
            let line = (0..<Int(14 + rnd() * 10)).map { _ in words[Int(rnd() * Double(words.count))] }.joined(separator: " ")
            let color = CGColor(red: rnd() * 0.4, green: rnd() * 0.4, blue: rnd() * 0.6, alpha: 1)
            let attr = NSAttributedString(string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                     kCTForegroundColorAttributeName as NSAttributedString.Key: color])
            ctx.textPosition = CGPoint(x: CGFloat(w) * 0.06, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            y -= CGFloat(h) / 50
        }
        return ctx.makeImage()!
    }
    var sizes = [Int](repeating: 0, count: fps * seconds)
    let lock = NSLock()
    let step = max(1, h / 360 * 60 / fps) * 2   // ~240 pt/s at 2x, like the quality suite
    var doc = page(0), docIndex = 0
    for i in 0..<(fps * seconds) {
        if i > 0 && i % (fps * 3) == 0 { docIndex += 1; doc = page(docIndex) }
        let offset = (i % (fps * 3)) * step % (h * 2)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(doc, in: CGRect(x: 0, y: -CGFloat(h * 2 - offset), width: CGFloat(w), height: CGFloat(h * 3)))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        let index = i
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb!, presentationTimeStamp: CMTime(value: Int64(i), timescale: Int32(fps)),
                                        duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            guard status == noErr, let sb else { return }
            lock.lock(); sizes[index] = CMSampleBufferGetTotalSampleSize(sb); lock.unlock()
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    }
    try! ([String(fps)] + sizes.map(String.init)).joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    let total = sizes.reduce(0, +)
    print("wrote \(sizes.count) frames, avg \(total / sizes.count) B, max \(sizes.max()!) B, \(Double(total) * 8 / Double(seconds) / 1e6) Mbps")
}

// MARK: - wire formats

// Frame header on streams: [u32 frameId][u64 sendNs][u32 length] then payload.
// Datagram: [u8 1][u32 frameId][u16 frag][u16 nfrags][u64 sendNs] payload
// NACK:     [u8 2][u32 frameId][u16 n]{[u16 frag]}
let noise: Data = { var d = Data(count: 4 << 20); d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }; return d }()

func percentile(_ v: [Double], _ p: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
}
func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

// MARK: - receiver

final class Receiver {
    let q = DispatchQueue(label: "recv")
    var offsetNs: Int64 = 0         // receiverClock = senderClock + offset
    var label = "", mode = ""
    var complete: [UInt32: UInt64] = [:]        // frameId -> completion (receiver clock)
    var sendNsOf: [UInt32: UInt64] = [:]
    var bytes = 0
    // datagram reassembly
    struct Partial { var have: Set<UInt16>; var n: UInt16; var sendNs: UInt64; var lastArrival: UInt64; var lastNack: UInt64; var nacks: Int }
    var partial: [UInt32: Partial] = [:]
    var maxSeen: UInt32 = 0
    var nackEnabled = false
    var nacksSent = 0, datagrams = 0
    var nackTimer: DispatchSourceTimer?
    var dgramReply: ((Data) -> Void)?
    var listeners: [NWListener] = []
    var keep: [AnyObject] = []

    func reset(_ cmd: [String: Any]) {
        label = cmd["label"] as? String ?? ""; mode = cmd["mode"] as? String ?? ""
        offsetNs = (cmd["offsetNs"] as? NSNumber)?.int64Value ?? 0
        nackEnabled = mode.hasSuffix("nack")
        complete = [:]; sendNsOf = [:]; partial = [:]; maxSeen = 0; bytes = 0; nacksSent = 0; datagrams = 0
    }

    func frameDone(_ id: UInt32, sendNs: UInt64, size: Int) {
        guard complete[id] == nil else { return }
        complete[id] = now(); sendNsOf[id] = sendNs; bytes += size
    }

    func summary(_ cmd: [String: Any]) -> String {
        let sent = (cmd["sent"] as? Int) ?? 0, srcDrops = (cmd["srcDrops"] as? Int) ?? 0
        let fps = (cmd["fps"] as? Int) ?? 60
        let ids = complete.keys.sorted()
        var lat: [Double] = [], serial: [Double] = []
        var shown: [UInt64] = []
        var last: UInt64 = 0
        // A decoder consumes frames in order: frame N shows no earlier than N-1.
        // Lost frames (datagram modes) are skipped here and counted separately;
        // in a real stream each one breaks the reference chain until recovery.
        for id in ids {
            let c = complete[id]!, s = Int64(sendNsOf[id]!) + offsetNs
            lat.append(Double(Int64(c) - s) / 1e6)
            let shownAt = max(c, last); last = shownAt; shown.append(shownAt)
            serial.append(Double(Int64(shownAt) - s) / 1e6)
        }
        let interval = 1000.0 / Double(fps)
        var gaps: [Double] = []
        for i in 1..<max(1, shown.count) { gaps.append(Double(shown[i] - shown[i - 1]) / 1e6) }
        let hitches = gaps.filter { $0 > interval * 2 }.count
        let lost = sent - srcDrops - ids.count
        let secs = Double(sent) / Double(fps)
        let dict: [String: Any] = [
            "label": label, "mode": mode, "sent": sent, "srcDrops": srcDrops, "got": ids.count, "lost": lost,
            "fpsShown": r1(Double(ids.count) / max(secs, 0.001)),
            "lat50": r1(percentile(lat, 0.5)), "lat95": r1(percentile(lat, 0.95)), "lat99": r1(percentile(lat, 0.99)), "latMax": r1(lat.max() ?? .nan),
            "ser95": r1(percentile(serial, 0.95)), "ser99": r1(percentile(serial, 0.99)),
            "gap99": r1(percentile(gaps, 0.99)), "gapMax": r1(gaps.max() ?? .nan), "hitches": hitches,
            "over50ms": serial.filter { $0 > 50 }.count, "over100ms": serial.filter { $0 > 100 }.count,
            "mbps": r1(Double(bytes) * 8 / max(secs, 0.001) / 1e6), "nacks": nacksSent, "datagrams": datagrams,
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]), encoding: .utf8)!
        print(json)
        return json
    }

    // Stream framing shared by TCP and QUIC streams.
    func readFrames(_ c: NWConnection, buffer: Data = Data()) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, err in
            var buf = buffer
            if let data { buf.append(data) }
            while buf.count >= 16 {
                let len = Int(buf.get(12, UInt32.self))
                guard buf.count >= 16 + len else { break }
                frameDone(buf.get(0, UInt32.self), sendNs: buf.get(4, UInt64.self), size: 16 + len)
                buf.removeSubrange(buf.startIndex..<(buf.startIndex + 16 + len))
                buf = Data(buf)
            }
            if done || err != nil { c.cancel(); return }
            readFrames(c, buffer: buf)
        }
    }

    func datagram(_ d: Data, reply: @escaping (Data) -> Void) {
        guard d.count >= 17, d[d.startIndex] == 1 else { return }
        datagrams += 1
        dgramReply = reply
        let id = d.get(1, UInt32.self), frag = d.get(5, UInt16.self), n = d.get(7, UInt16.self), sendNs = d.get(9, UInt64.self)
        guard complete[id] == nil else { return }
        var p = partial[id] ?? Partial(have: [], n: n, sendNs: sendNs, lastArrival: 0, lastNack: 0, nacks: 0)
        p.have.insert(frag); p.lastArrival = now()
        if p.have.count == Int(n) {
            partial[id] = nil
            frameDone(id, sendNs: sendNs, size: Int(n) * 1200)
        } else { partial[id] = p }
        if id > maxSeen { maxSeen = id; if nackEnabled { checkNacks() } }
    }

    // Ask for the missing fragments of any frame older than the newest one seen,
    // or that has been quiet for 4 ms (tail loss). Re-ask at most every 15 ms.
    func checkNacks() {
        guard let reply = dgramReply else { return }
        let t = now()
        for (id, var p) in partial {
            if id + 60 < maxSeen { partial[id] = nil; continue }          // give up (~1 s)
            guard id < maxSeen || t &- p.lastArrival > 4_000_000 else { continue }
            guard t &- p.lastNack > 15_000_000, p.nacks < 10 else { continue }
            let missing = (0..<p.n).filter { !p.have.contains($0) }
            var m = Data([2]); m.put(id); m.put(UInt16(min(missing.count, 500)))
            for f in missing.prefix(500) { m.put(f) }
            reply(m)
            p.lastNack = t; p.nacks += 1; partial[id] = p; nacksSent += 1
        }
    }

    func start(base: Int) {
        func listen(_ params: NWParameters, _ p: Int, _ handler: @escaping (NWConnection) -> Void) {
            let l = try! NWListener(using: params, on: port(p))
            l.newConnectionHandler = { c in c.start(queue: self.q); handler(c) }
            l.start(queue: q); listeners.append(l)
        }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        listen(NWParameters(tls: nil, tcp: tcp), base) { self.readFrames($0) }
        func readDatagrams(_ c: NWConnection) {
            c.receiveMessage { data, _, _, err in
                if let data { self.datagram(data) { m in c.send(content: m, completion: .idempotent) } }
                if err == nil { readDatagrams(c) }
            }
        }
        listen(.udp, base) { readDatagrams($0) }
        listen(NWParameters(quic: quicOptions(server: true, datagram: true)), base + 4) { readDatagrams($0) }
        // QUIC: one connection group per client, one inbound stream per frame (or one for all).
        let ql = try! NWListener(using: NWParameters(quic: quicOptions(server: true, datagram: false)), on: port(base + 1))
        ql.newConnectionGroupHandler = { g in
            g.newConnectionHandler = { s in s.start(queue: self.q); self.readFrames(s) }
            g.stateUpdateHandler = { st in print("quic server group \(st)") }
            g.start(queue: self.q); self.keep.append(g)
        }
        ql.stateUpdateHandler = { st in if case .failed(let e) = st { print("quic listener failed \(e)") } }
        ql.start(queue: q); listeners.append(ql)
        // Clock: reply with our clock.
        listen(.udp, base + 2) { c in
            func loop() { c.receiveMessage { d, _, _, e in
                if let d { var r = d; r.put(now()); c.send(content: r, completion: .idempotent) }
                if e == nil { loop() } } }
            loop()
        }
        // Control: newline-delimited JSON.
        listen(NWParameters(tls: nil, tcp: tcp), base + 3) { c in
            func loop(_ buf: Data) { c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, e in
                var b = buf; if let d { b.append(d) }
                while let nl = b.firstIndex(of: 10) {
                    let line = b[b.startIndex..<nl]; b = Data(b[(nl + 1)...])
                    guard let cmd = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if cmd["cmd"] as? String == "begin" { self.reset(cmd); c.send(content: Data("ok\n".utf8), completion: .idempotent) }
                    if cmd["cmd"] as? String == "end" {
                        // Let retransmissions land before judging.
                        self.q.asyncAfter(deadline: .now() + 1.5) {
                            c.send(content: Data((self.summary(cmd) + "\n").utf8), completion: .idempotent)
                        }
                    }
                }
                if !done && e == nil { loop(b) } } }
            loop(Data())
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(2))
        t.setEventHandler { if self.nackEnabled { self.checkNacks() } }
        t.resume(); nackTimer = t
        print("listening on \(base)...\(base + 4)")
    }
}

// MARK: - sender

final class Sender {
    let q = DispatchQueue(label: "send", qos: .userInteractive)
    let host: NWEndpoint.Host, base: Int, mode: String
    let sizes: [Int], fps: Int
    let seconds: Int, label: String
    let paceMbps: Double, inflightCap: Int
    let serviceClass: NWParameters.ServiceClass
    var tcp: NWConnection?, group: NWConnectionGroup?, stream: NWConnection?, dgram: NWConnection?
    var pending = 0, sent = 0, srcDrops = 0, resent = 0
    var history: [UInt32: [Data]] = [:]
    var paceFree: UInt64 = 0
    var control: NWConnection!
    let done = DispatchSemaphore(value: 0)

    init(host: String, mode: String, trace: String, seconds: Int, label: String, opts: [String: String]) {
        self.host = NWEndpoint.Host(host); self.mode = mode; self.seconds = seconds; self.label = label
        base = Int(opts["port"] ?? "9100")!
        paceMbps = Double(opts["pace"] ?? "0")!
        inflightCap = Int(opts["inflight"] ?? "3")!
        // svc=video|responsive|signaling: Network.framework service class A/B.
        switch opts["svc"] ?? "" {
        case "video": serviceClass = .interactiveVideo
        case "responsive": serviceClass = .responsiveData
        case "signaling": serviceClass = .signaling
        default: serviceClass = .bestEffort
        }
        let lines = try! String(contentsOfFile: trace, encoding: .utf8).split(separator: "\n").map { Int($0)! }
        fps = lines[0]; sizes = Array(lines.dropFirst())
    }

    func waitReady(_ c: NWConnection) {
        let s = DispatchSemaphore(value: 0)
        c.stateUpdateHandler = { st in
            switch st { case .ready: s.signal()
            case .failed(let e), .waiting(let e): print("\(self.mode) connection: \(e)")
            default: break }
        }
        c.start(queue: q); s.wait()
    }

    func clockOffset() -> Int64 {
        let c = NWConnection(host: host, port: port(base + 2), using: .udp)
        waitReady(c)
        var best: (rtt: UInt64, off: Int64) = (.max, 0)
        let s = DispatchSemaphore(value: 0)
        for _ in 0..<200 {
            var m = Data(); m.put(now())
            c.send(content: m, completion: .idempotent)
            c.receiveMessage { d, _, _, _ in
                let t1 = now()
                if let d, d.count == 16 {
                    let t0 = d.get(0, UInt64.self), tr = d.get(8, UInt64.self)
                    if t1 - t0 < best.rtt { best = (t1 - t0, Int64(tr) - Int64((t0 + t1) / 2)) }
                }
                s.signal()
            }
            _ = s.wait(timeout: .now() + 0.2)
            usleep(5_000)
        }
        c.cancel()
        print(String(format: "clock: min rtt %.2f ms, offset %.2f ms", Double(best.rtt) / 1e6, Double(best.off) / 1e6))
        return best.off
    }

    func controlCall(_ obj: [String: Any]) -> String {
        var line = try! JSONSerialization.data(withJSONObject: obj); line.append(10)
        control.send(content: line, completion: .idempotent)
        let s = DispatchSemaphore(value: 0); var reply = ""
        control.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in
            reply = d.map { String(decoding: $0, as: UTF8.self) } ?? ""; s.signal()
        }
        s.wait(); return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func connect() {
        switch mode {
        case "tcp":
            let o = NWProtocolTCP.Options(); o.noDelay = true   // as MacSender
            let p = NWParameters(tls: nil, tcp: o); p.serviceClass = serviceClass
            tcp = NWConnection(host: host, port: port(base), using: p); waitReady(tcp!)
        case "udp", "udpnack":
            let p = NWParameters.udp; p.serviceClass = serviceClass
            dgram = NWConnection(host: host, port: port(base), using: p); waitReady(dgram!); readNacks()
        case "qdgram", "qdgramnack":
            dgram = NWConnection(host: host, port: port(base + 4), using: NWParameters(quic: quicOptions(server: false, datagram: true)))
            waitReady(dgram!); readNacks()
            if let m = dgram!.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
                print("quic datagram frame size \(m.usableDatagramFrameSize)")
            }
        case "quic1", "quicN":
            let g = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: host, port: port(base + 1))),
                                      using: NWParameters(quic: quicOptions(server: false, datagram: false)))
            let s = DispatchSemaphore(value: 0)
            g.stateUpdateHandler = { st in
                print("quic group \(st)")
                if case .ready = st { s.signal() }
                if case .failed(let e) = st { print("quic group failed \(e)") }
                if case .waiting(let e) = st { print("quic group waiting \(e)") }
            }
            // Without an inbound-stream handler the group never leaves setup.
            g.newConnectionHandler = { $0.cancel() }
            g.start(queue: q); s.wait(); group = g
            if mode == "quic1" { stream = NWConnection(from: g)!; waitReady(stream!) }
        default: fatalError("unknown mode \(mode)")
        }
    }

    func readNacks() {
        dgram!.receiveMessage { [self] d, _, _, err in
            if let d, d.count >= 7, d[d.startIndex] == 2 {
                let id = d.get(1, UInt32.self), n = Int(d.get(5, UInt16.self))
                if let frags = history[id] {
                    for i in 0..<n {
                        let f = Int(d.get(7 + i * 2, UInt16.self))
                        if f < frags.count { dgram!.send(content: frags[f], completion: .idempotent); resent += 1 }
                    }
                }
            }
            if err == nil { readNacks() }
        }
    }

    func sendFrame(_ id: UInt32, size: Int) {
        let sendNs = now()
        switch mode {
        case "tcp", "quic1", "quicN":
            // Backpressure as in MacSender: drop at the source when `inflight`
            // frames still wait on their send completion.
            guard pending < inflightCap else { srcDrops += 1; return }
            var f = Data(); f.put(id); f.put(sendNs); f.put(UInt32(size))
            f.append(noise.prefix(size))
            pending += 1; sent += 1
            let c: NWConnection
            if mode == "quicN" {
                c = NWConnection(from: group!)!
                c.start(queue: q)
            } else { c = tcp ?? stream! }
            c.send(content: f, isComplete: mode == "quicN", completion: .contentProcessed { [self] e in
                pending -= 1
                if let e { print("send error \(e)") }
                if mode == "quicN" { q.asyncAfter(deadline: .now() + 5) { c.cancel() } }
            })
        default:
            let chunk = mode.hasPrefix("q") ? 1100 : 1200
            let n = max(1, (size + chunk - 1) / chunk)
            var frags: [Data] = []
            for i in 0..<n {
                var d = Data([1]); d.put(id); d.put(UInt16(i)); d.put(UInt16(n)); d.put(sendNs)
                d.append(noise.subdata(in: (i * chunk)..<min(size, (i + 1) * chunk)))
                frags.append(d)
            }
            sent += 1
            if mode.hasSuffix("nack") { history[id] = frags; history[id &- 120] = nil }
            if paceMbps <= 0 {
                for d in frags { dgram!.send(content: d, completion: .idempotent) }
            } else {
                // Spread the frame at `pace` Mbps instead of bursting it.
                let nsPerByte = 8_000.0 / paceMbps
                var t = max(now(), paceFree)
                for d in frags {
                    let at = t
                    q.asyncAfter(deadline: .now() + .nanoseconds(Int(at > now() ? at - now() : 0))) { self.dgram!.send(content: d, completion: .idempotent) }
                    t += UInt64(Double(d.count) * nsPerByte)
                }
                paceFree = t
            }
        }
    }

    func run() {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds + 30)) { print("timeout"); exit(3) }
        control = NWConnection(host: host, port: port(base + 3), using: .tcp); waitReady(control)
        let off = clockOffset()
        connect()
        _ = controlCall(["cmd": "begin", "label": label, "mode": mode, "offsetNs": off])
        let total = fps * seconds
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: q)
        var i = 0
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .nanoseconds(0))
        t.setEventHandler { [self] in
            if i >= total { t.cancel(); done.signal(); return }
            sendFrame(UInt32(i), size: sizes[i % sizes.count]); i += 1
        }
        t.resume()
        done.wait()
        Thread.sleep(forTimeInterval: 0.5)
        let r = controlCall(["cmd": "end", "sent": sent + srcDrops, "srcDrops": srcDrops, "fps": fps])
        print(r)
        if resent > 0 { print("resent fragments: \(resent)") }
    }
}

switch args.count > 1 ? args[1] : "" {
case "trace": makeTrace()
case "recv":
    let r = Receiver(); r.start(base: args.count > 2 ? Int(args[2])! : 9100)
    dispatchMain()
case "send":
    var opts: [String: String] = [:]
    for a in args.dropFirst(4) where a.contains("=") { let kv = a.split(separator: "=", maxSplits: 1); opts[String(kv[0])] = String(kv[1]) }
    let positional = args.dropFirst(5).filter { !$0.contains("=") }
    let seconds = positional.first.flatMap { Int($0) } ?? 30
    let label = positional.dropFirst().first ?? args[3]
    Sender(host: args[2], mode: args[3], trace: args[4], seconds: seconds, label: label, opts: opts).run()
    exit(0)
default:
    print("usage: see the header of nettest.swift"); exit(2)
}
