import XCTest

/// Round trips for the raw-video frame formats (PROTOCOL.md 6.8): what the
/// sender encodes must rebuild the same picture on the receiver.
final class RawFrameCodecTests: XCTestCase {
    /// Deterministic noise, so a failure reproduces.
    private struct Noise {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func byte() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    private struct Frame {
        let width: Int, height: Int
        var y: [UInt8]      // tightly packed: width bytes per row
        var c: [UInt8]      // interleaved CbCr, height / 2 rows of width bytes
    }

    private func noisyFrame(width: Int, height: Int) -> Frame {
        var noise = Noise()
        return Frame(width: width, height: height,
                     y: (0..<width * height).map { _ in noise.byte() },
                     c: (0..<width * height / 2).map { _ in noise.byte() })
    }

    /// A smooth picture, like a scaled-up video: compresses well.
    private func smoothFrame(width: Int, height: Int) -> Frame {
        Frame(width: width, height: height,
              y: (0..<width * height).map { UInt8(truncatingIfNeeded: (($0 % width) + ($0 / width)) / 6) },
              c: (0..<width * height / 2).map { UInt8(truncatingIfNeeded: 128 + ($0 / width) / 8) })
    }

    private func delta(_ a: Frame, _ b: Frame, maxChangedFraction: Double = 0.6) -> RawFrameCodec.DeltaResult {
        a.y.withUnsafeBytes { ay in
            a.c.withUnsafeBytes { ac in
                b.y.withUnsafeBytes { by in
                    b.c.withUnsafeBytes { bc in
                        RawFrameCodec.delta(previousY: ay.baseAddress!, previousC: ac.baseAddress!,
                                            currentY: by.baseAddress!, currentC: bc.baseAddress!,
                                            width: a.width, height: a.height,
                                            yStride: a.width, cStride: a.width, nowMs: 1_234,
                                            maxChangedFraction: maxChangedFraction)
                    }
                }
            }
        }
    }

    /// The payload without its 4-byte length prefix, as the receiver sees it.
    private func withPayload<T>(_ framed: Data, _ body: (UnsafeRawBufferPointer) -> T) -> T {
        framed.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0[4...])) }
    }

    private func apply(_ framed: Data, to frame: Frame) -> (ok: Bool, frame: Frame) {
        var out = frame
        let ok = withPayload(framed) { payload in
            out.y.withUnsafeMutableBytes { y in
                out.c.withUnsafeMutableBytes { c in
                    RawFrameCodec.applyDelta(payload, canvasY: y.baseAddress!, canvasC: c.baseAddress!)
                }
            }
        }
        return (ok, out)
    }

    private func deltaPayload(_ result: RawFrameCodec.DeltaResult,
                              file: StaticString = #filePath, line: UInt = #line) -> Data? {
        if case .delta(let data) = result { return data }
        XCTFail("expected a delta, got \(result)", file: file, line: line)
        return nil
    }

    // MARK: Changed tiles

    func testDeltaRebuildsChangedTilesIncludingPartialEdgeTiles() throws {
        // 200x130 is not a multiple of 64: the right and bottom tiles are partial.
        let a = noisyFrame(width: 200, height: 130)
        var b = a
        b.y[5 * 200 + 3] ^= 0xFF                       // inside the first tile
        b.y[129 * 200 + 199] ^= 0x01                   // the very last luma pixel
        b.c[64 * 200 + 100] ^= 0x10                    // chroma, bottom edge
        let payload = try XCTUnwrap(deltaPayload(delta(a, b)))
        let rebuilt = apply(payload, to: a)
        XCTAssertTrue(rebuilt.ok)
        XCTAssertEqual(rebuilt.frame.y, b.y)
        XCTAssertEqual(rebuilt.frame.c, b.c)
    }

    func testDeltaSendsOnlyTheTilesThatChanged() throws {
        let a = noisyFrame(width: 256, height: 128)         // 4 x 2 tiles
        var b = a
        b.y[70 * 256 + 130] ^= 0x55                         // one tile
        let payload = try XCTUnwrap(deltaPayload(delta(a, b)))
        let header = withPayload(payload) { RawFrameCodec.deltaHeader($0) }
        XCTAssertEqual(header?.count, 1)
        XCTAssertEqual(header?.width, 256)
        XCTAssertEqual(header?.height, 128)
        XCTAssertEqual(header?.captureMs, 1_234)
        // 40 bytes of header + index + 64 luma rows + 32 chroma rows of 64 bytes.
        XCTAssertEqual(payload.count, 4 + 36 + 4 + 96 * 64)
    }

    func testChromaOnlyChangeIsDetected() throws {
        let a = noisyFrame(width: 128, height: 128)
        var b = a
        b.c[10 * 128 + 5] ^= 0x01
        let payload = try XCTUnwrap(deltaPayload(delta(a, b)))
        XCTAssertEqual(apply(payload, to: a).frame.c, b.c)
    }

    func testIdenticalFramesProduceNothing() {
        let a = noisyFrame(width: 128, height: 128)
        guard case .identical = delta(a, a) else { return XCTFail("expected .identical") }
    }

    func testMostlyChangedFrameFallsBackToWholeFrame() {
        let a = noisyFrame(width: 256, height: 128)
        var noise = Noise(state: 7)
        let b = Frame(width: 256, height: 128, y: a.y.map { _ in noise.byte() }, c: a.c)
        guard case .full = delta(a, b) else { return XCTFail("expected .full") }
    }

    func testMalformedDeltaIsRejected() throws {
        let a = noisyFrame(width: 256, height: 128)
        var b = a
        b.y[3] ^= 1
        b.y[200 * 0 + 130] ^= 1
        let payload = try XCTUnwrap(deltaPayload(delta(a, b)))

        XCTAssertFalse(apply(payload.dropLast(10), to: a).ok, "truncated tile data")
        XCTAssertFalse(apply(payload + Data([0]), to: a).ok, "trailing bytes")

        var badIndex = payload
        badIndex.withUnsafeMutableBytes { raw in      // first tile index -> far outside the grid
            raw.storeBytes(of: UInt32(9_999).littleEndian, toByteOffset: 4 + 36, as: UInt32.self)
        }
        XCTAssertFalse(apply(badIndex, to: a).ok, "tile index out of range")

        XCTAssertNil(withPayload(Data(count: 40)) { RawFrameCodec.deltaHeader($0) }, "wrong magic")
    }

    // MARK: LZ4 strips

    private func compressed(_ frame: Frame) -> Data? {
        frame.y.withUnsafeBytes { y in
            frame.c.withUnsafeBytes { c in
                RawFrameCodec.compress(y: y.baseAddress!, c: c.baseAddress!,
                                       width: frame.width, height: frame.height, nowMs: 99)
            }
        }
    }

    /// Decode into planes whose rows are `padding` bytes longer than the picture.
    private func decompressed(_ framed: Data, width: Int, height: Int, padding: Int = 0) -> (ok: Bool, frame: Frame?) {
        let yStride = width + padding, cStride = width + padding
        var yPlane = [UInt8](repeating: 0xAA, count: yStride * height)
        var cPlane = [UInt8](repeating: 0xAA, count: cStride * height / 2)
        let ok: Bool = withPayload(framed) { payload in
            guard let header = RawFrameCodec.stripHeader(payload) else { return false }
            return yPlane.withUnsafeMutableBytes { y in
                cPlane.withUnsafeMutableBytes { c in
                    RawFrameCodec.decompress(payload, header: header, y: y.baseAddress!, c: c.baseAddress!,
                                             yStride: yStride, cStride: cStride)
                }
            }
        }
        guard ok else { return (false, nil) }
        func unpad(_ plane: [UInt8], rows: Int, stride: Int) -> [UInt8] {
            (0..<rows).flatMap { plane[$0 * stride..<$0 * stride + width] }
        }
        return (true, Frame(width: width, height: height,
                            y: unpad(yPlane, rows: height, stride: yStride),
                            c: unpad(cPlane, rows: height / 2, stride: cStride)))
    }

    func testSmoothFrameRoundTripsAndShrinks() throws {
        let frame = smoothFrame(width: 256, height: 200)    // 200 rows: a partial last strip
        let payload = try XCTUnwrap(compressed(frame))
        XCTAssertLessThan(payload.count, frame.y.count * 3 / 2 * 9 / 10)
        let result = decompressed(payload, width: 256, height: 200)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.frame?.y, frame.y)
        XCTAssertEqual(result.frame?.c, frame.c)
    }

    func testStripsDecodeIntoPaddedRows() throws {
        let frame = smoothFrame(width: 256, height: 200)
        let payload = try XCTUnwrap(compressed(frame))
        let result = decompressed(payload, width: 256, height: 200, padding: 64)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.frame?.y, frame.y)
        XCTAssertEqual(result.frame?.c, frame.c)
    }

    func testIncompressibleFrameIsNotCompressed() {
        XCTAssertNil(compressed(noisyFrame(width: 256, height: 128)))
    }

    func testStripsThatDoNotShrinkAreStoredAndStillRoundTrip() throws {
        // Flat top half compresses; the noisy bottom half is stored as is.
        var frame = noisyFrame(width: 256, height: 256)
        for i in 0..<(256 * 128) { frame.y[i] = 7 }
        for i in 0..<(256 * 64) { frame.c[i] = 128 }
        let payload = try XCTUnwrap(compressed(frame))
        let stored = withPayload(payload) { RawFrameCodec.stripHeader($0) }!
        let rawSizes = (0..<stored.count).map { i -> Int in
            let luma = i < stored.count / 2
            let rows = min(64, 256 - (luma ? i : i - stored.count / 2) * 64) / (luma ? 1 : 2)
            return rows * 256
        }
        XCTAssertTrue(zip(stored.sizes, rawSizes).contains { $0 == $1 }, "some strip is stored raw")
        XCTAssertTrue(zip(stored.sizes, rawSizes).contains { $0 < $1 }, "some strip is compressed")
        let result = decompressed(payload, width: 256, height: 256)
        XCTAssertEqual(result.frame?.y, frame.y)
        XCTAssertEqual(result.frame?.c, frame.c)
    }

    func testMalformedStripFrameIsRejected() throws {
        let frame = smoothFrame(width: 256, height: 200)
        let payload = try XCTUnwrap(compressed(frame))
        XCTAssertFalse(decompressed(payload.dropLast(5), width: 256, height: 200).ok, "truncated")
        XCTAssertFalse(decompressed(payload + Data([0]), width: 256, height: 200).ok, "trailing bytes")

        var wrongCount = payload
        wrongCount.withUnsafeBytes { _ in }
        wrongCount.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(3).littleEndian, toByteOffset: 4 + 16, as: UInt32.self)
        }
        XCTAssertFalse(decompressed(wrongCount, width: 256, height: 200).ok, "strip count does not match the height")

        // First strip's compressed bytes replaced by 0xFF: the LZ4 stream is invalid.
        let header = withPayload(payload) { RawFrameCodec.stripHeader($0) }!
        var garbled = payload
        for i in 0..<header.sizes[0] { garbled[4 + header.offsets[0] + i] = 0xFF }
        XCTAssertFalse(decompressed(garbled, width: 256, height: 200).ok, "corrupt LZ4 data")
    }
}
