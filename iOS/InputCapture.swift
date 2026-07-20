import UIKit

/// Captures Apple Pencil hover, stroke, and side double-tap on a host view.
/// Finger touches stay on VideoView's existing `touch` wire path.
final class InputCaptureEngine: NSObject, UIPencilInteractionDelegate {
    var onPencil: ((_ phase: PencilPhase, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double,
                    _ rotation: Double) -> Void)?
    var onBarrelButton: ((_ down: Bool, _ x: Double, _ y: Double) -> Void)?

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var hoverInRange = false
    private var penStrokes: [UInt64: PenStroke] = [:]
    private let tapMoveThreshold: CGFloat = 8
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
        onBarrelButton?(true, nx, ny)
        onBarrelButton?(false, nx, ny)
    }

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard activePens.isEmpty, let view = hostView else { return }
        guard let n = normalize?(gr.location(in: view)) else { return }
        switch gr.state {
        case .began, .changed:
            hoverInRange = true
            onPencil?(.hover, n.x, n.y, 0, 0, .pi / 2, 0)
        case .ended, .cancelled, .failed:
            hoverInRange = false
        default:
            break
        }
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard hostView != nil else { return }
        for touch in touches where touch.type == .pencil || touch.type == .stylus {
            emitPen(touch, event: event, ended: ended)
        }
    }

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool) {
        guard let view = hostView else { return }
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: view)
        guard let n = normalize?(loc) else { return }
        let (nx, ny) = (n.x, n.y)

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let altitude = Double(touch.altitudeAngle)

        var rotationDeg: Double = 0
        if #available(iOS 17.5, *) {
            rotationDeg = Double(touch.rollAngle) * 180.0 / .pi
        }

        if hoverInRange { hoverInRange = false }

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            penStrokes[id] = PenStroke(start: loc, sentDown: false)
            return
        }

        if !ended {
            guard var stroke = penStrokes[id] else { return }
            let dx = loc.x - stroke.start.x
            let dy = loc.y - stroke.start.y
            if !stroke.sentDown {
                guard sqrt(dx * dx + dy * dy) > tapMoveThreshold else { return }
                stroke.sentDown = true
                penStrokes[id] = stroke
                if let start = normalize?(stroke.start) {
                    emitPencil(.down, x: start.x, y: start.y, pressure: pressure,
                               azimuth: azimuth, altitude: altitude, rotation: rotationDeg)
                }
            }
            emitPencil(.move, x: nx, y: ny, pressure: pressure,
                       azimuth: azimuth, altitude: altitude, rotation: rotationDeg)
            for c in event?.coalescedTouches(for: touch) ?? [] where c !== touch {
                guard let cn = normalize?(c.location(in: view)) else { continue }
                emitPencil(.move, x: cn.x, y: cn.y,
                           pressure: min(Double(c.force), 1.0),
                           azimuth: Double(c.azimuthAngle(in: view)),
                           altitude: Double(c.altitudeAngle),
                           rotation: rotationDeg)
            }
            return
        }

        defer {
            activePens.remove(id)
            penStrokes.removeValue(forKey: id)
        }

        if let stroke = penStrokes[id], !stroke.sentDown {
            emitPencil(.down, x: nx, y: ny, pressure: pressure,
                       azimuth: azimuth, altitude: altitude, rotation: rotationDeg)
            emitPencil(.up, x: nx, y: ny, pressure: 0,
                       azimuth: azimuth, altitude: altitude, rotation: rotationDeg)
            return
        }

        emitPencil(.up, x: nx, y: ny, pressure: 0,
                   azimuth: azimuth, altitude: altitude, rotation: rotationDeg)
    }

    private func emitPencil(_ phase: PencilPhase, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double,
                            rotation: Double) {
        lastPencilNorm = (x, y)
        onPencil?(phase, x, y, pressure, azimuth, altitude, rotation)
    }
}
