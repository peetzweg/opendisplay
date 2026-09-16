// Compiled into the Mac sender, the iOS receiver and the Mac receiver (see
// project.yml `sources`). Foundation-only and free of any API newer than the
// receiver's deployment target.

import Foundation

/// Absorbs network jitter between arrival and playback.
///
/// Packets leave the Mac evenly spaced but arrive in bursts, and an audio
/// device consumes them at a fixed rate: hand it packets exactly as they land
/// and every late one is an audible gap. The buffer trades a little latency
/// for continuity — it holds `targetDepth` packets before playback starts, so
/// a burst has somewhere to go and a late packet has time to catch up.
///
/// Deliberately not a resampler or a clock-drift corrector. It reorders,
/// bounds, and reports; long-run drift between the Mac's clock and the
/// device's is left to the audio engine.
///
/// Not thread-safe: callers serialise on their own queue.
struct AudioJitterBuffer {

    /// Packets held before playback begins. At AAC-LC's 1024 samples per
    /// packet and 48kHz, each packet is ~21ms, so 3 is ~64ms — enough to ride
    /// out ordinary WiFi jitter without a latency people notice against video.
    static let defaultTarget = 3
    /// Hard ceiling. Past this the network is delivering faster than playback
    /// consumes (or playback stalled); dropping the oldest keeps latency
    /// bounded instead of letting the buffer grow into a delay.
    static let defaultCapacity = 12

    /// Ceiling for adaptive growth. At ~21ms per packet this is ~170ms, past
    /// which audio lags the picture more than it gains in continuity — better
    /// to accept the occasional gap than to drift visibly out of sync.
    static let maxAdaptiveTarget = 8

    private var packets: [AudioPacket] = []
    private var started = false

    /// Current pre-roll depth. Starts at `baseTarget` and grows when the link
    /// proves too jittery for it — see `enqueue`. Never shrinks within a
    /// session: a link that underran once will underrun again, and oscillating
    /// the target is audible as repeated re-buffering.
    private(set) var targetDepth: Int
    private let baseTarget: Int
    let capacity: Int
    /// How many times the target has been raised — reported so a link that
    /// needed help is distinguishable from one that never struggled.
    private(set) var adaptations = 0

    // Counters for the stats report; a silent buffer and a thrashing one look
    // identical from outside without them.
    private(set) var underruns = 0
    private(set) var dropped = 0
    private(set) var reordered = 0

    var depth: Int { packets.count }
    var isEmpty: Bool { packets.isEmpty }

    init(targetDepth: Int = defaultTarget, capacity: Int = defaultCapacity) {
        // A capacity below the target would drop packets before playback could
        // ever start, so the buffer would never produce a sound.
        let base = max(1, targetDepth)
        self.baseTarget = base
        self.targetDepth = base
        self.capacity = max(base, capacity)
    }

    /// Raise the pre-roll depth after an underrun.
    ///
    /// The starting target is a guess about a link we have not measured. One
    /// underrun is noise; repeated ones mean the guess is wrong for this
    /// network, and the buffer should hold more before playing. Growth is
    /// capped both by `maxAdaptiveTarget` (latency) and by `capacity` (there
    /// must be room above the target to absorb a burst).
    private mutating func adaptAfterUnderrun() {
        let ceiling = min(Self.maxAdaptiveTarget, capacity - 1)
        guard targetDepth < ceiling else { return }
        targetDepth += 1
        adaptations += 1
    }

    /// Queue a packet, ordering it by timestamp.
    ///
    /// Ordering matters because TCP guarantees byte order, not decode order
    /// across a reconnect: a session that migrates transports can deliver a
    /// packet from the old path after one from the new.
    mutating func enqueue(_ packet: AudioPacket) {
        if let last = packets.last, packet.ptsMs < last.ptsMs {
            // Out of order: insert at the right position rather than appending.
            let index = packets.firstIndex { $0.ptsMs > packet.ptsMs } ?? packets.count
            packets.insert(packet, at: index)
            reordered += 1
        } else {
            packets.append(packet)
        }

        while packets.count > capacity {
            packets.removeFirst()
            dropped += 1
        }
    }

    /// The next packet to play, or nil while the buffer is still filling.
    ///
    /// Returns nil in two distinct situations that deliberately behave the
    /// same way — pre-roll (not enough packets yet) and underrun (drained) —
    /// because the caller's response is identical: play silence and wait. Only
    /// the underrun counter tells them apart afterwards.
    mutating func dequeue() -> AudioPacket? {
        if !started {
            guard packets.count >= targetDepth else { return nil }
            started = true
        }
        guard !packets.isEmpty else {
            underruns += 1
            started = false     // re-fill before resuming, or we underrun every packet
            adaptAfterUnderrun()
            return nil
        }
        return packets.removeFirst()
    }

    /// Drop everything and re-arm pre-roll, keeping what has been learned
    /// about this link. For a resume, where the held packets are stale but the
    /// network is the same one that needed the deeper buffer.
    mutating func reset() {
        packets.removeAll(keepingCapacity: true)
        started = false
    }

    /// Drop everything and forget the adaptation too. For a new session, whose
    /// peer may be on an entirely different network — carrying over a target
    /// grown for a bad WiFi link would add latency a cable does not need.
    mutating func resetForNewSession() {
        reset()
        targetDepth = baseTarget
        adaptations = 0
    }

    /// Zero the counters after they have been reported.
    mutating func resetCounters() {
        underruns = 0
        dropped = 0
        reordered = 0
    }
}
