// InputCaptureEngine: Apple Pencil hover, stroke, and side-tap capture.
// Finger input stays on the legacy `touch` wire path in VideoLayerView.

import UIKit

/// Captures pencil and hover. Coordinates are normalized [0,1] in video space
/// (origin top-left) via the host view's normalize closure.
final class InputCaptureEngine: NSObject, UIPencilInteractionDelegate {
    var onPencil: ((_ phase: PencilPhase, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double,
                    _ rotation: Double, _ osMs: Double, _ captureMs: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ eraser: Bool) -> Void)?
    var onBarrelButton: ((_ down: Bool, _ x: Double, _ y: Double) -> Void)?

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var hoverInRange = false
    private var penStrokes: [UInt64: PenStroke] = [:]
    private let tapMoveThreshold: CGFloat = 8
    /// Last known pencil position in video-normalized coords (for side-tap right click).
    private var lastPencilNorm: (x: Double, y: Double)?

    private struct PenStroke {
        var start: CGPoint
        var sentDown: Bool
    }

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        view.addGestureRecognizer(hover)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard let (nx, ny) = lastPencilNorm else { return }
        Log.info("[input] capture pencil side tap → right click @ \(fmt(nx, ny))")
        onBarrelButton?(true, nx, ny)
        onBarrelButton?(false, nx, ny)
    }

    private func norm(_ p: CGPoint) -> (Double, Double)? {
        guard let n = normalize?(p) else { return nil }
        return (n.x, n.y)
    }

    private func emitPencil(_ phase: PencilPhase, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double,
                            rotation: Double, osDeliveredMs: Double) {
        lastPencilNorm = (x, y)
        let captureMs = Date().timeIntervalSince1970 * 1000
        onPencil?(phase, x, y, pressure, azimuth, altitude, rotation, osDeliveredMs, captureMs)
    }

    // MARK: - Hover (pen in air)

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard activePens.isEmpty, let view = hostView else { return }
        guard let (nx, ny) = norm(gr.location(in: view)) else { return }
        let osMs = Date().timeIntervalSince1970 * 1000
        switch gr.state {
        case .began, .changed:
            if !hoverInRange {
                hoverInRange = true
                Log.info("[input] capture hover enter")
            }
            emitPencil(.hover, x: nx, y: ny, pressure: 0, azimuth: 0, altitude: .pi / 2, rotation: 0, osDeliveredMs: osMs)
        case .ended, .cancelled, .failed:
            if hoverInRange {
                hoverInRange = false
                Log.info("[input] capture hover exit")
            }
        default:
            break
        }
    }

    // MARK: - Pencil on screen

    private func isPencil(_ touch: UITouch) -> Bool {
        switch touch.type {
        case .pencil, .stylus: return true
        default: return false
        }
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, phase: String, ended: Bool,
                osDeliveredMs: Double) {
        guard hostView != nil else { return }
        for touch in touches where isPencil(touch) {
            emitPen(touch, event: event, ended: ended, osDeliveredMs: osDeliveredMs)
        }
    }

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool, osDeliveredMs: Double) {
        guard let view = hostView else { return }
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: view)
        guard let (nx, ny) = norm(loc) else { return }

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let altitude = Double(touch.altitudeAngle)

        var rotationDeg: Double = 0
        if #available(iOS 17.5, *) {
            rotationDeg = Double(touch.rollAngle) * 180.0 / .pi
        }

        if hoverInRange {
            hoverInRange = false
        }

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            penStrokes[id] = PenStroke(start: loc, sentDown: false)
            Log.info("[input] capture pen contact began (waiting for move/tap)")
            return
        }

        if !ended {
            guard var stroke = penStrokes[id] else { return }
            let dx = loc.x - stroke.start.x
            let dy = loc.y - stroke.start.y
            let moved = sqrt(dx * dx + dy * dy)
            if !stroke.sentDown {
                guard moved > tapMoveThreshold else { return }
                stroke.sentDown = true
                penStrokes[id] = stroke
                if let (sx, sy) = norm(stroke.start) {
                    Log.info("[input] capture pen stroke down @ \(fmt(sx, sy))")
                    emitPencil(.down, x: sx, y: sy, pressure: pressure, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
                }
            }
            emitPencil(.move, x: nx, y: ny, pressure: pressure, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
            for c in event?.coalescedTouches(for: touch) ?? [] where c !== touch {
                guard let (cx, cy) = norm(c.location(in: view)) else { continue }
                emitPencil(.move, x: cx, y: cy,
                           pressure: min(Double(c.force), 1.0),
                           azimuth: Double(c.azimuthAngle(in: view)),
                           altitude: Double(c.altitudeAngle),
                           rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
            }
            return
        }

        defer {
            activePens.remove(id)
            penStrokes.removeValue(forKey: id)
        }

        if let stroke = penStrokes[id], !stroke.sentDown {
            Log.info("[input] capture pen tap → down+up @ \(fmt(nx, ny))")
            emitPencil(.down, x: nx, y: ny, pressure: pressure, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
            emitPencil(.up, x: nx, y: ny, pressure: 0, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
            return
        }

        Log.info("[input] capture pen up @ \(fmt(nx, ny))")
        emitPencil(.up, x: nx, y: ny, pressure: 0, azimuth: azimuth, altitude: altitude, rotation: rotationDeg, osDeliveredMs: osDeliveredMs)
    }

    private func fmt(_ x: Double, _ y: Double) -> String {
        String(format: "%.3f,%.3f", x, y)
    }
}
