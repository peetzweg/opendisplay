// Encode and decode the raw-video frame formats of PROTOCOL.md 6.8 ("ODRD"
// changed tiles, "ODRZ" LZ4 strips), shared by the Mac sender and the Mac
// receiver and covered by round-trip tests. Pure functions over NV12 planes:
// no CoreVideo, no networking.
//
// Encoders return the payload *with* its 4-byte big-endian length prefix, as
// the sender puts it on the wire. Decoders take the payload *without* it, as
// the receiver's deframer hands it over. Header fields are little-endian.
//
// Loops are plain `while` loops on purpose: range iteration is very slow in
// unoptimised (Debug) builds, which these hot paths run in during development.

import Foundation
import Compression

enum RawFrameCodec {
    static let tile = 64
    static let stripRows = 64

    // MARK: Changed tiles ("ODRD")

    enum DeltaResult {
        case identical            // nothing changed: send no frame
        case full                 // too much changed: send a whole frame
        case delta(Data)
    }

    struct DeltaHeader {
        let width: Int, height: Int, tile: Int, count: Int
        let captureMs: Int64, sendMs: Int64
    }

    /// Changed 64x64 tiles of `current` against `previous` (same size, both
    /// readable for the call). `maxChangedFraction`: above it a whole frame is
    /// cheaper than the patch.
    static func delta(previousY pY: UnsafeRawPointer, previousC pC: UnsafeRawPointer,
                      currentY cY: UnsafeRawPointer, currentC cC: UnsafeRawPointer,
                      width: Int, height: Int, yStride: Int, cStride: Int,
                      nowMs: Int64, maxChangedFraction: Double = 0.6) -> DeltaResult {
        let tile = Self.tile
        let tilesX = (width + tile - 1) / tile, tilesY = (height + tile - 1) / tile

        var dirty = [UInt8](repeating: 0, count: tilesX * tilesY)
        dirty.withUnsafeMutableBufferPointer { out in
            let flags = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: tilesY) { ty in
                let rows = min(tile, height - ty * tile)
                var tx = 0
                while tx < tilesX {
                    let x0 = tx * tile
                    let bytes = min(tile, width - x0)
                    var differs = false
                    var row = ty * tile
                    let lumaEnd = row + rows
                    while row < lumaEnd, !differs {
                        if memcmp(pY + row * yStride + x0, cY + row * yStride + x0, bytes) != 0 { differs = true }
                        row += 1
                    }
                    row = ty * tile / 2
                    let chromaEnd = row + rows / 2
                    while row < chromaEnd, !differs {
                        if memcmp(pC + row * cStride + x0, cC + row * cStride + x0, bytes) != 0 { differs = true }
                        row += 1
                    }
                    if differs { flags[ty * tilesX + tx] = 1 }
                    tx += 1
                }
            }
        }
        var changed = 0
        var i = 0
        while i < dirty.count { changed += Int(dirty[i]); i += 1 }
        if changed == 0 { return .identical }
        if Double(changed) > Double(tilesX * tilesY) * maxChangedFraction { return .full }

        let headerSize = 4 + 36
        var size = headerSize
        var ty = 0
        while ty < tilesY {
            let rows = min(tile, height - ty * tile)
            var tx = 0
            while tx < tilesX {
                if dirty[ty * tilesX + tx] != 0 { size += 4 + (rows + rows / 2) * min(tile, width - tx * tile) }
                tx += 1
            }
            ty += 1
        }
        guard let buffer = malloc(size) else { return .full }
        var lengthBE = UInt32(size - 4).bigEndian
        memcpy(buffer, &lengthBE, 4)
        memcpy(buffer + 4, Array("ODRD".utf8), 4)
        put(UInt32(width), into: buffer, at: 8); put(UInt32(height), into: buffer, at: 12)
        put(UInt32(tile), into: buffer, at: 16); put(UInt32(changed), into: buffer, at: 20)
        put(nowMs, into: buffer, at: 24); put(nowMs, into: buffer, at: 32)
        var offset = headerSize
        ty = 0
        while ty < tilesY {
            let rows = min(tile, height - ty * tile)
            var tx = 0
            while tx < tilesX {
                if dirty[ty * tilesX + tx] != 0 {
                    let x0 = tx * tile
                    let bytes = min(tile, width - x0)
                    put(UInt32(ty * tilesX + tx), into: buffer, at: offset); offset += 4
                    var src = cY + ty * tile * yStride + x0
                    var r = 0
                    while r < rows {
                        memcpy(buffer + offset, src, bytes)
                        src += yStride
                        offset += bytes
                        r += 1
                    }
                    src = cC + ty * (tile / 2) * cStride + x0
                    r = 0
                    while r < rows / 2 {
                        memcpy(buffer + offset, src, bytes)
                        src += cStride
                        offset += bytes
                        r += 1
                    }
                }
                tx += 1
            }
            ty += 1
        }
        return .delta(Data(bytesNoCopy: buffer, count: size, deallocator: .free))
    }

    static func deltaHeader(_ frame: UnsafeRawBufferPointer) -> DeltaHeader? {
        guard frame.count >= 36, magic(frame) == "ODRD" else { return nil }
        let header = DeltaHeader(width: u32(frame, 4), height: u32(frame, 8), tile: u32(frame, 12),
                                 count: u32(frame, 16), captureMs: i64(frame, 20), sendMs: i64(frame, 28))
        guard header.width > 0, header.height > 0, header.tile > 0, header.tile % 2 == 0 else { return nil }
        return header
    }

    /// Patch the tiles of a delta frame into tightly packed planes (row length
    /// `width`). False when the frame is malformed; the canvas may then be half
    /// patched and must not be shown or reused.
    static func applyDelta(_ frame: UnsafeRawBufferPointer,
                           canvasY: UnsafeMutableRawPointer, canvasC: UnsafeMutableRawPointer) -> Bool {
        guard let header = deltaHeader(frame) else { return false }
        let width = header.width, height = header.height, tile = header.tile
        let tilesX = (width + tile - 1) / tile, tilesY = (height + tile - 1) / tile
        let base = frame.baseAddress!
        var offset = 36
        var n = 0
        while n < header.count {
            n += 1
            guard offset + 4 <= frame.count else { return false }
            let index = u32(frame, offset)
            offset += 4
            let ty = index / tilesX, tx = index % tilesX
            guard ty < tilesY else { return false }
            let rows = min(tile, height - ty * tile)
            let bytes = min(tile, width - tx * tile)
            guard offset + (rows + rows / 2) * bytes <= frame.count else { return false }
            let x0 = tx * tile
            var dst = canvasY + ty * tile * width + x0
            var r = 0
            while r < rows {
                memcpy(dst, base + offset, bytes)
                dst += width
                offset += bytes
                r += 1
            }
            dst = canvasC + ty * (tile / 2) * width + x0
            r = 0
            while r < rows / 2 {
                memcpy(dst, base + offset, bytes)
                dst += width
                offset += bytes
                r += 1
            }
        }
        return offset == frame.count
    }

    // MARK: LZ4 strips ("ODRZ")

    struct StripHeader {
        let width: Int, height: Int, strip: Int, count: Int
        let captureMs: Int64, sendMs: Int64
        let sizes: [Int]          // compressed size of every strip (== raw size when stored as is)
        let offsets: [Int]        // where every strip starts in the frame
    }

    /// A whole frame as independent LZ4 strips (64 luma rows each, then the
    /// matching 32 CbCr rows). Planes must be tightly packed (stride == width).
    /// Nil when it would not save at least 10%; the caller then sends a plain frame.
    static func compress(y: UnsafeRawPointer, c: UnsafeRawPointer,
                         width: Int, height: Int, nowMs: Int64) -> Data? {
        let strip = stripRows
        let bands = (height + strip - 1) / strip
        let count = bands * 2
        let ySize = width * height
        guard let scratch = malloc(ySize * 3 / 2) else { return nil }
        defer { free(scratch) }
        var sizes = [Int](repeating: 0, count: count)
        sizes.withUnsafeMutableBufferPointer { out in
            let sizesOut = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let luma = i < bands
                let band = luma ? i : i - bands
                let rows = min(strip, height - band * strip)
                let rawSize = (luma ? rows : rows / 2) * width
                let source = luma ? y + band * strip * width : c + band * (strip / 2) * width
                let target = scratch + (luma ? band * strip * width : ySize + band * (strip / 2) * width)
                let n = compression_encode_buffer(target.assumingMemoryBound(to: UInt8.self), rawSize,
                                                  source.assumingMemoryBound(to: UInt8.self), rawSize,
                                                  nil, COMPRESSION_LZ4)
                if n == 0 || n >= rawSize {
                    memcpy(target, source, rawSize)
                    sizesOut[i] = rawSize
                } else {
                    sizesOut[i] = n
                }
            }
        }
        var total = 0
        var k = 0
        while k < count { total += sizes[k]; k += 1 }
        if total * 10 > ySize * 3 / 2 * 9 { return nil }

        let headerSize = 4 + 36 + 4 * count
        let size = headerSize + total
        guard let buffer = malloc(size) else { return nil }
        var lengthBE = UInt32(size - 4).bigEndian
        memcpy(buffer, &lengthBE, 4)
        memcpy(buffer + 4, Array("ODRZ".utf8), 4)
        put(UInt32(width), into: buffer, at: 8); put(UInt32(height), into: buffer, at: 12)
        put(UInt32(strip), into: buffer, at: 16); put(UInt32(count), into: buffer, at: 20)
        put(nowMs, into: buffer, at: 24); put(nowMs, into: buffer, at: 32)
        var offset = headerSize
        k = 0
        while k < count {
            put(UInt32(sizes[k]), into: buffer, at: 40 + 4 * k)
            let luma = k < bands
            let band = luma ? k : k - bands
            memcpy(buffer + offset, scratch + (luma ? band * strip * width : ySize + band * (strip / 2) * width), sizes[k])
            offset += sizes[k]
            k += 1
        }
        return Data(bytesNoCopy: buffer, count: size, deallocator: .free)
    }

    static func stripHeader(_ frame: UnsafeRawBufferPointer) -> StripHeader? {
        guard frame.count >= 36, magic(frame) == "ODRZ" else { return nil }
        let width = u32(frame, 4), height = u32(frame, 8), strip = u32(frame, 12), count = u32(frame, 16)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, strip > 0, strip % 2 == 0 else { return nil }
        let bands = (height + strip - 1) / strip
        guard count == bands * 2, 36 + 4 * count <= frame.count else { return nil }
        var sizes = [Int](repeating: 0, count: count)
        var offsets = [Int](repeating: 0, count: count)
        var offset = 36 + 4 * count
        var i = 0
        while i < count {
            sizes[i] = u32(frame, 36 + 4 * i)
            offsets[i] = offset
            offset += sizes[i]
            i += 1
        }
        guard offset == frame.count else { return nil }
        return StripHeader(width: width, height: height, strip: strip, count: count,
                           captureMs: i64(frame, 20), sendMs: i64(frame, 28), sizes: sizes, offsets: offsets)
    }

    /// Decode every strip, in parallel, into planes with the given row strides.
    /// False if any strip is malformed.
    static func decompress(_ frame: UnsafeRawBufferPointer, header: StripHeader,
                           y yBase: UnsafeMutableRawPointer, c cBase: UnsafeMutableRawPointer,
                           yStride: Int, cStride: Int) -> Bool {
        let width = header.width, height = header.height, strip = header.strip
        let bands = (height + strip - 1) / strip
        let base = frame.baseAddress!
        var failed: Int32 = 0
        let failedLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: header.count) { index in
            let luma = index < bands
            let band = luma ? index : index - bands
            let rows = min(strip, height - band * strip) / (luma ? 1 : 2)
            let rawSize = rows * width
            let stride = luma ? yStride : cStride
            let firstRow = band * (luma ? strip : strip / 2)
            let target = (luma ? yBase : cBase) + firstRow * stride
            let source = base + header.offsets[index]
            // Decode into a temporary only when the destination rows are padded.
            let direct = stride == width
            let scratch = direct ? nil : malloc(rawSize)
            let output = direct ? target : scratch!
            var ok = true
            if header.sizes[index] == rawSize {
                memcpy(output, source, rawSize)
            } else {
                ok = compression_decode_buffer(output.assumingMemoryBound(to: UInt8.self), rawSize,
                                               source.assumingMemoryBound(to: UInt8.self), header.sizes[index],
                                               nil, COMPRESSION_LZ4) == rawSize
            }
            if !direct, let scratch {
                var row = 0
                while row < rows {
                    memcpy(target + row * stride, scratch + row * width, width)
                    row += 1
                }
                free(scratch)
            }
            if !ok { failedLock.lock(); failed += 1; failedLock.unlock() }
        }
        return failed == 0
    }

    // MARK: Little-endian helpers

    private static func put<T: FixedWidthInteger>(_ value: T, into buffer: UnsafeMutableRawPointer, at offset: Int) {
        var v = value.littleEndian
        memcpy(buffer + offset, &v, MemoryLayout<T>.size)
    }

    private static func u32(_ frame: UnsafeRawBufferPointer, _ offset: Int) -> Int {
        Int(UInt32(littleEndian: frame.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    }

    private static func i64(_ frame: UnsafeRawBufferPointer, _ offset: Int) -> Int64 {
        Int64(littleEndian: frame.loadUnaligned(fromByteOffset: offset, as: Int64.self))
    }

    private static func magic(_ frame: UnsafeRawBufferPointer) -> String {
        String(decoding: UnsafeRawBufferPointer(rebasing: frame[0..<4]), as: UTF8.self)
    }
}
