import XCTest

/// The jitter buffer is where "packets arrived" becomes "audio played", and
/// every one of its edge cases is audible: a gap, a blip of stale audio, or a
/// latency that grows all session. Pure logic, so all of it is testable.
final class AudioJitterBufferTests: XCTestCase {

    private func packet(_ ptsMs: Double) -> AudioPacket {
        AudioPacket(codec: .aacLC, hasConfig: false, sampleRate: 48_000,
                    channels: 2, ptsMs: ptsMs, payload: Data([0x01]))
    }

    private func fill(_ buffer: inout AudioJitterBuffer, count: Int, from: Double = 0) {
        for i in 0..<count { buffer.enqueue(packet(from + Double(i) * 21)) }
    }

    // MARK: - Pre-roll

    func testNothingPlaysUntilTheTargetDepthIsReached() {
        // Playing the first packet on arrival defeats the buffer: there is
        // nothing held back to cover the next late one.
        var buffer = AudioJitterBuffer(targetDepth: 3, capacity: 12)
        buffer.enqueue(packet(0))
        XCTAssertNil(buffer.dequeue())
        buffer.enqueue(packet(21))
        XCTAssertNil(buffer.dequeue())
        buffer.enqueue(packet(42))
        XCTAssertNotNil(buffer.dequeue())
    }

    func testPlaybackRunsInTimestampOrderOncePreRolled() {
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 12)
        fill(&buffer, count: 4)
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 0)
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 21)
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 42)
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 63)
    }

    // MARK: - Underrun

    func testDrainingCountsAnUnderrun() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        buffer.enqueue(packet(0))
        XCTAssertNotNil(buffer.dequeue())
        XCTAssertNil(buffer.dequeue())
        XCTAssertEqual(buffer.underruns, 1)
    }

    func testUnderrunReArmsPreRollInsteadOfPlayingEachArrival() {
        // Without re-arming, a buffer that ran dry hands over every subsequent
        // packet the instant it lands — underrunning again on the next one, and
        // the one after. The recovery must rebuild a cushion.
        var buffer = AudioJitterBuffer(targetDepth: 3, capacity: 12)
        fill(&buffer, count: 3)
        while buffer.dequeue() != nil {}
        XCTAssertEqual(buffer.underruns, 1)

        // Refill to the CURRENT target, which the underrun just raised — the
        // pre-underrun depth is deliberately no longer enough.
        let target = buffer.targetDepth
        for i in 0..<(target - 1) {
            buffer.enqueue(packet(100 + Double(i) * 21))
            XCTAssertNil(buffer.dequeue(), "must re-fill to target before resuming")
        }
        buffer.enqueue(packet(100 + Double(target) * 21))
        XCTAssertNotNil(buffer.dequeue())
    }

    // MARK: - Overrun

    func testExceedingCapacityDropsTheOldest() {
        // Dropping the newest would keep the stalest audio and grow latency;
        // dropping the oldest keeps playback close to live.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 4)
        fill(&buffer, count: 6)
        XCTAssertEqual(buffer.depth, 4)
        XCTAssertEqual(buffer.dropped, 2)
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 42, "the two oldest should be gone")
    }

    func testSustainedOverrunKeepsDepthBounded() {
        var buffer = AudioJitterBuffer(targetDepth: 3, capacity: 8)
        fill(&buffer, count: 500)
        XCTAssertEqual(buffer.depth, 8)
    }

    // MARK: - Reordering

    func testOutOfOrderPacketIsPlacedByTimestamp() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        buffer.enqueue(packet(0))
        buffer.enqueue(packet(42))
        buffer.enqueue(packet(21))     // late arrival

        XCTAssertEqual(buffer.reordered, 1)
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 0)
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 21)
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 42)
    }

    func testInOrderArrivalsCountNoReordering() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        fill(&buffer, count: 10)
        XCTAssertEqual(buffer.reordered, 0)
    }

    // MARK: - Reset

    func testResetDropsHeldAudioAndRearmsPreRoll() {
        // Stale packets from a previous session would otherwise play as a blip
        // of the old stream over the new one.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 12)
        fill(&buffer, count: 5)
        buffer.reset()

        XCTAssertTrue(buffer.isEmpty)
        buffer.enqueue(packet(1000))
        XCTAssertNil(buffer.dequeue(), "pre-roll must be re-armed after a reset")
    }

    func testResetCountersClearsWithoutDiscardingAudio() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 2)
        fill(&buffer, count: 5)
        XCTAssertGreaterThan(buffer.dropped, 0)

        buffer.resetCounters()
        XCTAssertEqual(buffer.dropped, 0)
        XCTAssertEqual(buffer.underruns, 0)
        XCTAssertEqual(buffer.reordered, 0)
        XCTAssertEqual(buffer.depth, 2, "counters reset must not discard packets")
    }

    // MARK: - Adaptation

    func testTargetGrowsAfterAnUnderrun() {
        // The starting target is a guess about an unmeasured link. When it
        // proves too shallow, the buffer should hold more rather than keep
        // gapping at the same depth.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 12)
        XCTAssertEqual(buffer.targetDepth, 2)

        fill(&buffer, count: 2)
        while buffer.dequeue() != nil {}

        XCTAssertEqual(buffer.targetDepth, 3)
        XCTAssertEqual(buffer.adaptations, 1)
    }

    func testTargetStopsGrowingAtTheLatencyCeiling() {
        // Unbounded growth would trade every gap for latency until audio
        // visibly trailed the picture.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 64)
        for _ in 0..<50 {
            fill(&buffer, count: buffer.targetDepth)
            while buffer.dequeue() != nil {}
        }
        XCTAssertLessThanOrEqual(buffer.targetDepth, AudioJitterBuffer.maxAdaptiveTarget)
    }

    func testTargetNeverGrowsIntoCapacity() {
        // A target at capacity could never pre-roll: the packet that would
        // complete it evicts the oldest, so depth never reaches the target.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 4)
        for _ in 0..<50 {
            fill(&buffer, count: buffer.targetDepth)
            while buffer.dequeue() != nil {}
        }
        XCTAssertLessThan(buffer.targetDepth, buffer.capacity)

        // And it must still be able to play after all that adaptation.
        fill(&buffer, count: buffer.capacity)
        XCTAssertNotNil(buffer.dequeue())
    }

    func testAStableLinkNeverAdapts() {
        var buffer = AudioJitterBuffer(targetDepth: 3, capacity: 12)
        fill(&buffer, count: 12)
        for _ in 0..<9 { XCTAssertNotNil(buffer.dequeue()) }
        XCTAssertEqual(buffer.adaptations, 0)
        XCTAssertEqual(buffer.targetDepth, 3)
    }

    func testResetKeepsWhatTheLinkTaughtUs() {
        // A resume is the same network: throwing away the learned depth would
        // make it re-learn by underrunning again, audibly.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 12)
        fill(&buffer, count: 2)
        while buffer.dequeue() != nil {}
        let learned = buffer.targetDepth

        buffer.reset()
        XCTAssertEqual(buffer.targetDepth, learned)
    }

    func testNewSessionForgetsTheAdaptation() {
        // A new peer may be on a cable where the WiFi-grown target is pure
        // added latency.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 12)
        fill(&buffer, count: 2)
        while buffer.dequeue() != nil {}
        XCTAssertGreaterThan(buffer.targetDepth, 2)

        buffer.resetForNewSession()
        XCTAssertEqual(buffer.targetDepth, 2)
        XCTAssertEqual(buffer.adaptations, 0)
    }

    // MARK: - Construction

    func testCapacityBelowTargetIsRaisedSoPlaybackCanStart() {
        // A capacity under the target would drop packets before pre-roll ever
        // completed, and the buffer would never produce a sound.
        var buffer = AudioJitterBuffer(targetDepth: 5, capacity: 2)
        XCTAssertGreaterThanOrEqual(buffer.capacity, buffer.targetDepth)
        fill(&buffer, count: 5)
        XCTAssertNotNil(buffer.dequeue())
    }

    func testZeroTargetStillPlays() {
        var buffer = AudioJitterBuffer(targetDepth: 0, capacity: 4)
        buffer.enqueue(packet(0))
        XCTAssertNotNil(buffer.dequeue())
    }

    func testDefaultsGiveRoomAboveTheTarget() {
        let buffer = AudioJitterBuffer()
        XCTAssertGreaterThan(buffer.capacity, buffer.targetDepth)
    }
}
