// Compiled into the iOS receiver and the Mac receiver (see project.yml
// `sources`). Everything here must exist on the RECEIVER's deployment target,
// which is several majors below the sender's — CI builds the receiver app to
// catch a newer API sneaking in.

import AVFoundation
import Foundation

/// A snapshot of the audio path's health, for the overlay and the wire report.
struct AudioStats {
    var depth = 0          // packets held right now
    var target = 0         // pre-roll depth, which adapts upward on underruns
    var underruns = 0
    var dropped = 0
    var reordered = 0
    var adaptations = 0    // times the target grew this session
}

/// Decodes AAC audio packets and plays them.
///
/// Feeding is decoupled from playback by a jitter buffer: packets arrive in
/// network bursts, the engine consumes them at a fixed rate. A drain timer
/// moves packets between the two, so a late packet costs latency rather than
/// a gap.
///
/// Every failure here is non-fatal by construction. Audio is an optional
/// addition to a display, and a device that cannot decode it must still show
/// the picture.
final class AudioPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    /// Serialises the buffer and the engine; packets arrive on the network
    /// queue and the drain timer fires on its own.
    private let queue = DispatchQueue(label: "receiver.audio")
    private var buffer = AudioJitterBuffer()
    private var drainTimer: DispatchSourceTimer?
    private var running = false
    private var loggedFormat = false
    private var loggedStartFailure = false
    /// Packets handed to the player node and not yet consumed by it. See
    /// `maxScheduled` — this is the backpressure that paces playback.
    private var scheduled = 0
    private var decodeFailures = 0
    private var loggedFirstPlayback = false
    private var loggedDryStatus = false
    private var loggedNoDescriptions = false

    /// User-facing mute. Packets keep flowing and the buffer keeps draining —
    /// muting only silences output, so unmuting resumes in sync instead of
    /// playing a backlog.
    var isMuted = false

    // MARK: - Lifecycle

    /// Prepare the engine. Safe to call repeatedly.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.buffer.reset()
            self.scheduled = 0
            self.startDrainTimer()
        }
    }

    /// Start a new session: drop held audio and forget the buffer depth
    /// learned from the previous peer, which may have been on a different
    /// network entirely.
    func startNewSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.resetForNewSession()
        }
        start()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.drainTimer?.cancel()
            self.drainTimer = nil
            self.player.stop()
            if self.engine.isRunning { self.engine.stop() }
            self.buffer.reset()
            self.scheduled = 0
            self.converter = nil
            self.sourceFormat = nil
            self.loggedFormat = false
            self.loggedFirstPlayback = false
            self.decodeFailures = 0
        }
    }

    /// Drop buffered audio without tearing the engine down — for a new session
    /// or a resume, where held packets are stale.
    func flush() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.reset()
            self.scheduled = 0
            self.player.stop()
            if self.engine.isRunning { self.player.play() }
        }
    }

    // MARK: - Feeding

    func enqueue(_ packet: AudioPacket) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.buffer.enqueue(packet)
        }
    }

    /// Counters for the stats report, and the current buffer depth.
    ///
    /// Consuming: the counters are zeroed, so each reported figure covers the
    /// interval since the last call. Use `peekStats` for anything that reads
    /// more often, or it will starve this of counts.
    func drainStats() -> AudioStats {
        queue.sync {
            let stats = currentStats
            buffer.resetCounters()
            return stats
        }
    }

    /// The same figures without clearing them — for the live overlay, which
    /// samples every second while the wire report drains every five.
    func peekStats() -> AudioStats {
        queue.sync { currentStats }
    }

    private var currentStats: AudioStats {
        AudioStats(depth: buffer.depth,
                   target: buffer.targetDepth,
                   underruns: buffer.underruns,
                   dropped: buffer.dropped,
                   reordered: buffer.reordered,
                   adaptations: buffer.adaptations)
    }

    // MARK: - Playback

    /// Wake up often enough to keep the engine topped up.
    ///
    /// The tick only decides *when to look*; `maxScheduled` decides how much is
    /// actually handed over, so a fast tick costs nothing and simply means the
    /// engine is refilled promptly once it has room.
    private func startDrainTimer() {
        drainTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    /// How many packets may sit scheduled inside the player node at once.
    ///
    /// This, not the timer, is what paces playback: a packet is pulled only
    /// when the engine has room, so the buffer drains at exactly the rate the
    /// hardware consumes audio. The earlier version pulled a fixed two packets
    /// per 10 ms tick — 200/s against an arrival rate of ~47/s (1024 samples at
    /// 48 kHz is ~21 ms of audio) — so it emptied the buffer roughly four times
    /// faster than it filled and underran continuously.
    private static let maxScheduled = 3

    private func drain() {
        guard running else { return }
        while scheduled < Self.maxScheduled {
            guard let packet = buffer.dequeue() else { return }
            play(packet)
        }
    }

    private func play(_ packet: AudioPacket) {
        guard let pcm = decode(packet) else {
            // Silence with a full buffer means every packet is failing to
            // decode; without this the two are indistinguishable from outside.
            decodeFailures += 1
            if decodeFailures == 1 || decodeFailures % 200 == 0 {
                Log.info("audio: decode failed (\(decodeFailures) so far) — no sound")
            }
            return
        }
        guard ensureEngineRunning(for: pcm.format) else { return }
        if !loggedFirstPlayback {
            loggedFirstPlayback = true
            Log.info("audio: playing \(Int(pcm.format.sampleRate))Hz "
                     + "\(pcm.format.channelCount)ch, engine running=\(engine.isRunning) "
                     + "volume=\(player.volume) muted=\(isMuted)")
        }
        if isMuted { return }   // decoded and dequeued, just not heard
        // The completion handler is the pacing signal: it fires when the engine
        // has consumed this buffer, which is what lets `drain` pull the next
        // one at the hardware's rate instead of a timer's.
        scheduled += 1
        player.scheduleBuffer(pcm) { [weak self] in
            guard let self else { return }
            self.queue.async { self.scheduled = max(0, self.scheduled - 1) }
        }
        if !player.isPlaying { player.play() }
    }

    // MARK: - Decoding

    private func decode(_ packet: AudioPacket) -> AVAudioPCMBuffer? {
        guard let converter = converter(for: packet),
              let outputFormat else { return nil }

        let compressed = AVAudioCompressedBuffer(
            format: converter.inputFormat,
            packetCapacity: 1,
            maximumPacketSize: max(packet.payload.count, 1))
        compressed.byteLength = UInt32(packet.payload.count)
        compressed.packetCount = 1
        packet.payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            compressed.data.copyMemory(from: base, byteCount: packet.payload.count)
        }
        // AAC-LC is 1024 samples per packet; the description tells the decoder
        // how much of `data` this packet occupies.
        // A nil descriptor array means the decoder gets no packet boundary and
        // rejects the frame — worth knowing, since it fails identically to a
        // malformed payload.
        if compressed.packetDescriptions == nil, !loggedNoDescriptions {
            loggedNoDescriptions = true
            Log.info("audio: compressed buffer has no packetDescriptions — decoder will reject frames")
        }
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.payload.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat,
        // Exactly one AAC-LC frame: 1024 samples, which is what one packet
        // decodes to. Asking for more (this was 2048) makes the converter
        // consume the packet, find it cannot fill the request, and return
        // inputRanDry having produced no PCM at all — a silent failure on every
        // single packet, with a perfectly valid frame going in.
                                         frameCapacity: 1024) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }

        switch status {
        case .haveData:
            return pcm.frameLength > 0 ? pcm : nil
        case .inputRanDry, .endOfStream:
            // Not an error in AVAudioConverter's eyes, so the `.error` branch
            // never fires and nothing was logged — which is why a decode that
            // fails on every packet looked silent from outside.
            if !loggedDryStatus {
                loggedDryStatus = true
                Log.info("audio: converter returned \(status == .inputRanDry ? "inputRanDry" : "endOfStream")"
                         + " for a \(packet.payload.count)B packet — no PCM produced")
            }
            return nil
        case .error:
            if let error { Log.info("audio decode error: \(error)") }
            return nil
        @unknown default:
            return nil
        }
    }

    /// Build (or reuse) the decoder for this packet's format.
    private func converter(for packet: AudioPacket) -> AVAudioConverter? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(packet.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(packet.channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let inFormat = AVAudioFormat(streamDescription: &description) else { return nil }

        // AAC needs its AudioSpecificConfig before it can decode anything, and
        // an ASBD alone does not carry one — without it the decoder builds
        // happily and then rejects every frame, which is exactly what it did.
        //
        // For AAC-LC the config is two bytes fully determined by the sample
        // rate and channel count, so it is reconstructed below rather than
        // sent, and applied to the converter once it exists.

        if let converter, let sourceFormat, sourceFormat == inFormat { return converter }

        // Float32 deinterleaved is what AVAudioEngine wants; letting it convert
        // again downstream would be a second resample for nothing.
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: Double(packet.sampleRate),
                                            channels: AVAudioChannelCount(packet.channels)),
              let made = AVAudioConverter(from: inFormat, to: outFormat) else {
            Log.info("audio: no decoder for \(packet.sampleRate)Hz \(packet.channels)ch")
            return nil
        }

        if let cookie = AudioPacket.aacLCCookie(sampleRate: packet.sampleRate,
                                                channels: packet.channels) {
            made.magicCookie = cookie
        }

        converter = made
        sourceFormat = inFormat
        outputFormat = outFormat
        if !loggedFormat {
            loggedFormat = true
            Log.info("audio: decoding \(packet.sampleRate)Hz \(packet.channels)ch")
        }
        // The graph is wired for the old format; rebuild it for this one.
        teardownGraph()
        return made
    }

    // MARK: - Engine

    private func ensureEngineRunning(for format: AVAudioFormat) -> Bool {
        if engine.isRunning, player.engine != nil { return true }

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            loggedStartFailure = false
            return true
        } catch {
            // Log once: this is called per packet, and a device that refuses to
            // start the engine refuses every time.
            if !loggedStartFailure {
                loggedStartFailure = true
                Log.info("audio: engine would not start (\(error)) — no playback")
            }
            return false
        }
    }

    private func teardownGraph() {
        player.stop()
        if engine.isRunning { engine.stop() }
        if player.engine != nil { engine.disconnectNodeOutput(player) }
    }
}
