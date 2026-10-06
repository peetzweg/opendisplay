import Foundation

struct DisplayDiscoverySize: Equatable {
    let width: Int
    let height: Int

    var description: String { "\(width)x\(height)" }
}

struct DisplayDiscoverySnapshot {
    let coreGraphicsOnline: Bool?
    let coreGraphicsActive: Bool?
    let shareableContentDisplayCount: Int
    let shareableDisplaySize: DisplayDiscoverySize?

    func diagnosis(expectedSize: DisplayDiscoverySize?) -> String {
        if let shareableDisplaySize {
            guard let expectedSize, shareableDisplaySize == expectedSize else {
                return "listed in ScreenCaptureKit at \(shareableDisplaySize.description)"
                    + (expectedSize.map { ", expected \($0.description)" } ?? "")
            }
            return "available in ScreenCaptureKit at \(shareableDisplaySize.description)"
        }
        if coreGraphicsOnline == true {
            return "online in CoreGraphics but missing from ScreenCaptureKit"
        }
        if coreGraphicsOnline == false {
            return "not online in CoreGraphics or ScreenCaptureKit"
        }
        return "missing from ScreenCaptureKit; CoreGraphics online state unavailable"
    }

    func summary(expectedSize: DisplayDiscoverySize?) -> String {
        "CoreGraphics online=\(state(coreGraphicsOnline)) active=\(state(coreGraphicsActive)); "
            + "ScreenCaptureKit displays=\(shareableContentDisplayCount), "
            + diagnosis(expectedSize: expectedSize)
    }

    private func state(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "yes" : "no"
    }
}
