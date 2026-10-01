import Foundation

/// The receiver's `hello` (PROTOCOL.md 6.1), as the sender reads it.
struct PhoneInfo: Decodable {
    let pixelsWide: Int   // legacy trio (deprecated, PROTOCOL.md 6.1): the
    let pixelsHigh: Int   //  desktop as 2x pixels in the current orientation;
    let scale: Double     //  read only when `panel` is absent
    let device: String?   // "iPad" / "iPhone" (older receivers omit it)
    let id: String?       // per-install identity (older receivers omit it) —
                          // lets the controller match the same physical device
                          // across USB and WiFi
    let pv: Int?          // receiver protocol version (issue #132); absent on
                          // every pre-handshake install → treat as protocol 1
    let cursorPort: Int?  // UDP port for the cursor side channel (PROTOCOL.md
                          // 6.3); absent = cursor stays on TCP
    let addrs: [String]?  // every address the receiver is reachable on
                          // (PROTOCOL.md 6.4); probed for a cable upgrade
    let maxEncodeWide: Int?  // receiver's decode ceiling in pixels (PROTOCOL.md
    let maxEncodeHigh: Int?  //  6.5): caps the stream, and with it the desktop
    let displayMaxFrameRate: Int?       // presentation ceiling; absent = legacy 60
    let videoCaps: [VideoCapability]?   // codec-specific joint decode constraints
    let power: [String]?  // power actions the receiver accepts on THIS session
                          // (PROTOCOL.md 6.6); absent = none offered
    let panel: PanelInfo? // the receiver's panel facts (PROTOCOL.md 6.7);
                          // absent on older receivers → legacy facts

    var kind: String { device ?? "device" }
    var protocolVersion: Int { pv ?? WireProtocol.assumedWhenAbsent }

    /// What the sender knows about the receiver's panel, in its current
    /// orientation: `panel` when it is valid, else the legacy reading of
    /// `pixelsWide/High` as a 2x panel. `hello.scale` is never read: it was
    /// never honoured, and it is fractional on some receivers.
    var facts: PanelFacts { panel?.facts ?? legacyFacts }

    /// `panel` was sent but fails validation (PROTOCOL.md 6.7): the sender
    /// uses the legacy facts and says so once.
    var hasInvalidPanel: Bool { panel != nil && panel?.facts == nil }

    var legacyFacts: PanelFacts {
        PanelFacts(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, scale: 2,
                   pointsWide: nil, pointsHigh: nil)
    }
}

/// `hello.panel` as sent. Decoding never fails the hello: a malformed field
/// only invalidates `facts`, so the session falls back to the legacy trio.
struct PanelInfo: Decodable, Equatable {
    let pixelsWide: Int?
    let pixelsHigh: Int?
    let scale: Double?
    let pointsWide: Int?
    let pointsHigh: Int?

    private enum CodingKeys: String, CodingKey {
        case pixelsWide, pixelsHigh, scale, pointsWide, pointsHigh
    }

    init(pixelsWide: Int?, pixelsHigh: Int?, scale: Double?,
         pointsWide: Int? = nil, pointsHigh: Int? = nil) {
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.scale = scale
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
    }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        pixelsWide = (try? c?.decodeIfPresent(Int.self, forKey: .pixelsWide)) ?? nil
        pixelsHigh = (try? c?.decodeIfPresent(Int.self, forKey: .pixelsHigh)) ?? nil
        scale = (try? c?.decodeIfPresent(Double.self, forKey: .scale)) ?? nil
        pointsWide = (try? c?.decodeIfPresent(Int.self, forKey: .pointsWide)) ?? nil
        pointsHigh = (try? c?.decodeIfPresent(Int.self, forKey: .pointsHigh)) ?? nil
    }

    /// Validated facts, or nil. Never partially applied: physical pixels of
    /// at least 2, a finite positive scale, and points either both absent or
    /// both at least 2.
    var facts: PanelFacts? {
        guard let pixelsWide, let pixelsHigh, pixelsWide >= 2, pixelsHigh >= 2,
              let scale, scale.isFinite, scale > 0 else { return nil }
        switch (pointsWide, pointsHigh) {
        case (nil, nil):
            return PanelFacts(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, scale: scale,
                              pointsWide: nil, pointsHigh: nil)
        case let (w?, h?) where w >= 2 && h >= 2:
            return PanelFacts(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, scale: scale,
                              pointsWide: w, pointsHigh: h)
        default:
            return nil
        }
    }
}
