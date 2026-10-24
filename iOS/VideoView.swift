// The streaming surface: a UIKit view hosting the video layer, with touch,
// scroll, Apple Pencil and local cursor echo. UIKit-only (no SwiftUI): the
// SwiftUI app wraps it in `VideoLayerView`, and a UIKit app can host it
// directly.

import UIKit
import AVFoundation

// MARK: - Touch sampling

extension UIEvent {
    /// Every position UIKit recorded for `touch` in this update, oldest first.
    ///
    /// The panel samples faster than UIKit delivers, so a single `touchesMoved`
    /// stands for several real positions. This batch is that whole history and
    /// its *last* entry is `touch` itself, so forward the list as it comes:
    /// sending `touch` alongside it puts the newest sample ahead of its own
    /// history and emits it twice, which reads as backtracking on fast strokes.
    /// Falls back to the touch alone when UIKit coalesced nothing.
    func samples(for touch: UITouch) -> [UITouch] {
        let batch = coalescedTouches(for: touch) ?? []
        return batch.isEmpty ? [touch] : batch
    }
}

// MARK: - Video layer host view

/// UIView whose backing layer is the AVSampleBufferDisplayLayer.
/// Forwards touches as normalized video-space coordinates (touchscreen mode).
final class VideoView: UIView {
    weak var receiver: StreamReceiver?
    var metalRenderer: MetalVideoRenderer?
    let inputEngine = InputCaptureEngine()

    private let cursorLayer: CALayer = {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 10
        // Position updates arrive at 120Hz — implicit animations would
        // smear the cursor behind every move.
        layer.actions = ["position": NSNull(), "contents": NSNull(),
                         "bounds": NSNull(), "hidden": NSNull()]
        return layer
    }()
    private var cursorNormSize = CGSize.zero
    private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
    private var cursorVisible = false

    private var lastLoggedLayout = ""

    /// Wire this view to `receiver`: the video sink (system layer or Metal),
    /// touch/pencil input, scroll, and the local cursor echo. Called once,
    /// right after init, by whichever app hosts the view.
    func attach(receiver: StreamReceiver, displayLayer: AVSampleBufferDisplayLayer,
                useMetal: Bool) {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        self.receiver = receiver

        Log.info("video view: metal=\(useMetal)")
        if useMetal, let renderer = MetalVideoRenderer() {
            Log.info("metal renderer active")
            metalRenderer = renderer
            layer.addSublayer(renderer.metalLayer)
            receiver.onDecodedFrame = { [weak renderer] pixelBuffer, captureMs in
                renderer?.render(pixelBuffer, captureMs: captureMs)
            }
            renderer.onPresented = { [weak receiver] presentedTime, captureMs in
                receiver?.recordPresented(presentedTime: presentedTime, captureMs: captureMs)
            }
        } else {
            receiver.onDecodedFrame = nil   // route frames back to AVSBDL
            displayLayer.frame = bounds
            layer.addSublayer(displayLayer)
        }

        inputEngine.normalize = { [weak self] point in self?.normalized(point) }
        inputEngine.onPencil = { [weak receiver] phase, x, y, pressure, azimuth, altitude in
            receiver?.sendPencil(phase: phase, x: x, y: y,
                                 pressure: pressure, azimuth: azimuth,
                                 altitude: altitude)
        }
        inputEngine.onProximity = { [weak receiver] entering, x, y in
            receiver?.sendProximity(entering: entering, x: x, y: y)
        }
        inputEngine.install(on: self)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(didTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        // Local cursor echo: position updates ride the ~2ms control path
        // instead of the ~30ms video path, so the pointer feels native.
        receiver.onCursor = { [weak self] x, y, visible in
            self?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak self] image, anchor, normSize in
            self?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        // Replay the sprite/position that arrived before this view existed
        // (first frames land after the connect-time sprite) or that the
        // previous view held (metal-renderer toggle rebuilds the view tree).
        if let sprite = receiver.cursorSprite {
            setCursorSprite(sprite.image, anchor: sprite.anchor, normSize: sprite.normSize)
        }
        let state = receiver.cursorState
        moveCursor(x: state.x, y: state.y, visible: state.visible)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let renderer = metalRenderer {
            // The metal layer scales its drawable to fill its frame, so
            // the frame itself must be the aspect-fit rect.
            renderer.metalLayer.frame = videoRect() ?? bounds
        } else {
            // AVSBDL aspect-fits internally (videoGravity) — full bounds.
            layer.sublayers?.first?.frame = bounds
        }
        if cursorLayer.superlayer == nil { layer.addSublayer(cursorLayer) }
        updateCursorLayout()
        CATransaction.commit()
        // Rotation diagnostics — one line per layout change.
        let video = receiver?.videoSize ?? .zero
        let line = "layout: bounds=\(Int(bounds.width))x\(Int(bounds.height))"
            + " video=\(Int(video.width))x\(Int(video.height))"
            + " layer=\(Int(layer.sublayers?.first?.frame.width ?? -1))x\(Int(layer.sublayers?.first?.frame.height ?? -1))"
        if line != lastLoggedLayout {
            lastLoggedLayout = line
            Log.info(line)
        }
    }

    /// Aspect-fit rect of the video inside the view (inverse of normalized()).
    private func videoRect() -> CGRect? {
        guard let video = receiver?.videoSize, video != .zero,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func moveCursor(x: Double, y: Double, visible: Bool) {
        cursorNorm = CGPoint(x: x, y: y)
        cursorVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible || cursorLayer.contents == nil
        updateCursorLayout()
        CATransaction.commit()
    }

    func setCursorSprite(_ image: CGImage, anchor: CGPoint, normSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image
        cursorLayer.anchorPoint = anchor
        cursorNormSize = normSize
        cursorLayer.isHidden = !cursorVisible
        updateCursorLayout()
        CATransaction.commit()
    }

    private func updateCursorLayout() {
        guard let rect = videoRect(), cursorNormSize != .zero else { return }
        cursorLayer.bounds = CGRect(x: 0, y: 0,
                                    width: cursorNormSize.width * rect.width,
                                    height: cursorNormSize.height * rect.height)
        cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                       y: rect.minY + cursorNorm.y * rect.height)
    }

    // The video is aspect-fit inside the view; map view coords into the
    // displayed video rect and normalize to [0,1].
    fileprivate func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
        guard let video = receiver?.videoSize, video != .zero,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        let origin = CGPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2)
        let x = (point.x - origin.x) / size.width
        let y = (point.y - origin.y) / size.height
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    private func isFinger(_ touch: UITouch) -> Bool {
        if touch.type == .direct { return true }
        // Trackpad/mouse pointers (iPadOS 13.4+) drive the same path.
        if #available(iOS 13.4, *), touch.type == .indirectPointer { return true }
        return false
    }

    private func isPencil(_ touch: UITouch) -> Bool {
        touch.type == .pencil
    }

    private var twoFingerActive = false
    private var lastPan = CGPoint.zero
    private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)

    @objc func didTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard let video = receiver?.videoSize, video != .zero else { return }
        switch recognizer.state {
        case .began:
            twoFingerActive = true
            lastPan = .zero
            // macOS delivers scroll to whatever sits under the cursor, and
            // the cursor no longer follows the fingers now that a press is
            // withheld until it commits. Put it on the gesture once, up
            // front, so the scroll lands on the window being touched. Once
            // only: a real trackpad does not drag the cursor while
            // scrolling, and moving it mid-gesture would change the target.
            if let n = normalized(recognizer.location(in: self)) {
                lastNorm = n
                receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
            }
        case .changed:
            let t = recognizer.translation(in: self)
            let scale = min(bounds.width / video.width, bounds.height / video.height)
            // Deltas in video pixels, natural-scrolling direction.
            receiver?.sendScroll(dx: (t.x - lastPan.x) / scale,
                                 dy: (t.y - lastPan.y) / scale)
            lastPan = t
        default:
            twoFingerActive = false
        }
    }

    // A press is only a click once we know a second finger is not coming.
    // Sending `began` on contact posted a mouse-down we then had to take
    // back, and taking it back only works when UIKit happens to deliver
    // `cancelled`; when the pan recognizer misses and we get a plain
    // `ended` instead, that down/up pair *is* a click, which is why every
    // other two-finger scroll opened whatever sat under the first finger.
    // So hold the down until the gesture commits to being one.
    private var pendingDown: (x: Double, y: Double)?
    private var downSent = false
    private var holdTimer: DispatchWorkItem?

    /// Movement (in points) that turns a held press into a drag.
    private let dragSlop: CGFloat = 10
    /// A press this long with no second finger is a deliberate hold, so
    /// commit it: press-and-hold menus and drag handles need the button.
    private let holdDelay: TimeInterval = 0.12
    private var pendingDownPoint: CGPoint = .zero

    /// Emit the withheld `began`, at the point the finger first landed so a
    /// drag starts where the user touched rather than where slop was crossed.
    private func commitPendingDown() {
        guard let p = pendingDown, !downSent else { return }
        downSent = true
        holdTimer?.cancel()
        holdTimer = nil
        receiver?.sendTouch(phase: "began", x: p.x, y: p.y)
    }

    /// Drop the press without a trace. Nothing reached the Mac, so there is
    /// no button to release and no click to suppress.
    private func discardPendingDown() {
        pendingDown = nil
        downSent = false
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func send(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
        let fingers = touches.filter { isFinger($0) }
        guard !fingers.isEmpty else { return }
        // Ignore single-finger events while a two-finger gesture runs,
        // and end the click if a second finger joins mid-press.
        if twoFingerActive || (event?.allTouches?.filter { isFinger($0) }.count ?? 1) > 1 {
            if downSent {
                receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
            }
            discardPendingDown()
            return
        }
        guard let touch = fingers.first,
              let norm = normalized(touch.location(in: self)) else { return }
        lastNorm = norm

        switch phase {
        case "began":
            let location = touch.location(in: self)
            pendingDown = norm
            pendingDownPoint = location
            downSent = false
            let work = DispatchWorkItem { [weak self] in self?.commitPendingDown() }
            holdTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
            return
        case "ended":
            // A tap: nothing was posted yet, so post the whole click now.
            if pendingDown != nil, !downSent { commitPendingDown() }
            // No down means the press was already discarded (a second
            // finger took it), so there is nothing to release.
            if downSent { receiver?.sendTouch(phase: "ended", x: norm.x, y: norm.y) }
            discardPendingDown()
            return
        case "cancelled":
            if downSent {
                receiver?.sendTouch(phase: "cancelled", x: norm.x, y: norm.y)
            }
            discardPendingDown()
            return
        case "moved":
            if pendingDown != nil, !downSent {
                let moved = hypot(touch.location(in: self).x - pendingDownPoint.x,
                                  touch.location(in: self).y - pendingDownPoint.y)
                // Below slop the finger is still deciding: track the cursor
                // (the Mac turns a move without a down into mouseMoved) but
                // keep the button up so a second finger can still cancel.
                if moved > dragSlop { commitPendingDown() }
            }
        default:
            break
        }

        if phase == "moved", let event {
            // Forward every coalesced sample so the Mac gets the full-rate
            // drag, then UIKit's predicted touch so the cursor leads toward
            // where the finger will be (~1 frame of perceived latency back;
            // corrected by the next real sample).
            for t in event.samples(for: touch) {
                if let n = normalized(t.location(in: self)) {
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
            }
            if let predicted = event.predictedTouches(for: touch)?.last,
               let n = normalized(predicted.location(in: self)) {
                receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
            }
            return
        }
        receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
    }

    private func sendPencilAsTouch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
        guard let touch = touches.first,
              let norm = normalized(touch.location(in: self)) else { return }
        lastNorm = norm
        if phase == "moved", let event {
            for t in event.samples(for: touch) {
                if let n = normalized(t.location(in: self)) {
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
            }
            if let predicted = event.predictedTouches(for: touch)?.last,
               let n = normalized(predicted.location(in: self)) {
                receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
            }
            return
        }
        receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
    }

    private func routeTouches(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?, ended: Bool) {
        let pencil = touches.filter { isPencil($0) }
        let finger = touches.filter { isFinger($0) }
        let usePencilWire = receiver?.macSupportsPencilWire ?? false

        if !pencil.isEmpty {
            if usePencilWire {
                inputEngine.handle(pencil, event: event, ended: ended)
            } else {
                sendPencilAsTouch(phase, pencil, event)
            }
        }
        // Palm rejection: ignore resting fingers while the pen is down.
        if !finger.isEmpty && !inputEngine.hasActivePen {
            send(phase, finger, event)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        routeTouches("began", touches, event, ended: false)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        routeTouches("moved", touches, event, ended: false)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        routeTouches("ended", touches, event, ended: true)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        routeTouches("cancelled", touches, event, ended: true)
    }
}

// MARK: - Apple Pencil capture

/// Captures Apple Pencil hover and stroke on a host view.
/// Finger touches stay on VideoView's existing `touch` wire path.
///
/// TODO: Capture Apple Pencil Pro barrel roll (UIKit rollAngle, iOS 17.5+) once
/// hardware is available for testing.
final class InputCaptureEngine: NSObject {
    var onPencil: ((_ phase: String, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ x: Double, _ y: Double) -> Void)?

    /// True while at least one pen contact is on the glass (palm rejection).
    var hasActivePen: Bool { !activePens.isEmpty }

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var proximityActive = false

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        // Hover tilt/azimuth on the recognizer is iOS 16.4. Pencil hover needs
        // an M2 iPad Pro or newer, which never runs anything older, so
        // skipping the recognizer below 16.4 loses nothing on those devices.
        if #available(iOS 16.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
            hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
            view.addGestureRecognizer(hover)
        }
    }

    @available(iOS 13.0, *)
    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard #available(iOS 16.4, *) else { return }
        guard activePens.isEmpty, let view = hostView else { return }
        guard let n = normalize?(gr.location(in: view)) else { return }
        switch gr.state {
        case .began:
            openProximity(x: n.x, y: n.y)
            fallthrough
        case .changed:
            let azimuth = Double(gr.azimuthAngle(in: view))
            let altitude = Double(gr.altitudeAngle)
            onPencil?("hover", n.x, n.y, 0, azimuth, altitude)
        case .ended, .cancelled, .failed:
            guard activePens.isEmpty else { return }
            closeProximity(x: n.x, y: n.y)
        default:
            break
        }
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard hostView != nil else { return }
        for touch in touches where touch.type == .pencil {
            emitPen(touch, event: event, ended: ended)
        }
    }

    private func openProximity(x: Double, y: Double) {
        guard !proximityActive else { return }
        proximityActive = true
        onProximity?(true, x, y)
    }

    private func closeProximity(x: Double, y: Double) {
        guard proximityActive else { return }
        proximityActive = false
        onProximity?(false, x, y)
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

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            openProximity(x: nx, y: ny)
            emitPencil("down", x: nx, y: ny, pressure: pressure,
                       azimuth: azimuth, altitude: altitude)
            return
        }

        if !ended {
            for c in event?.samples(for: touch) ?? [touch] {
                guard let cn = normalize?(c.location(in: view)) else { continue }
                emitPencil("move", x: cn.x, y: cn.y,
                           pressure: min(Double(c.force), 1.0),
                           azimuth: Double(c.azimuthAngle(in: view)),
                           altitude: Double(c.altitudeAngle))
            }
            return
        }

        defer { activePens.remove(id) }
        emitPencil("up", x: nx, y: ny, pressure: 0,
                   azimuth: azimuth, altitude: altitude)
        closeProximity(x: nx, y: ny)
    }

    private func emitPencil(_ phase: String, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double) {
        onPencil?(phase, x, y, pressure, azimuth, altitude)
    }
}
