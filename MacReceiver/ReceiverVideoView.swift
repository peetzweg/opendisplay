// The production streaming surface is a CAMetalLayer in the normal Core
// Animation tree. Its cursor sprite is another CALayer in that same tree, so
// pointer updates do not wait for a 4.5K video encode and do not trigger the
// WindowServer plane transitions seen with AVSampleBufferDisplayLayer.
//
// Input mapping: hover moves the sender's cursor ("moved" with no button —
// the sender injects .mouseMoved), click-drag is began/moved/ended (left
// mouse down/drag/up), scroll wheel / trackpad scroll forwards as "scroll".
// The local hardware cursor is hidden over the video; the sprite echoed from
// the sender (which carries the true shape: arrow, I-beam, resize…) is drawn
// in its place on the low-latency control path.

import SwiftUI
import AppKit
import AVFoundation
import Combine

struct VideoHostView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let receiver: DisplayReceiver

    func makeNSView(context: Context) -> ReceiverVideoView {
        let view = ReceiverVideoView()
        view.receiver = receiver
        view.attach(displayLayer: displayLayer)

        if receiver.metalRenderer != nil {
            receiver.onCursor = { [weak view] x, y, visible in
                view?.moveCursor(x: x, y: y, visible: visible)
            }
            receiver.onCursorImage = { [weak view] image, anchor, normSize in
                view?.setCursorSprite(image, anchor: anchor, normSize: normSize)
            }
        } else {
            // A separate cursor CALayer over AVSampleBufferDisplayLayer can
            // trigger WindowServer plane transitions on affected systems.
            receiver.onCursor = nil
            receiver.onCursorImage = nil
        }
        // The sender keeps one input injector across reconnects — if a drag
        // was in flight when the link dropped, its isDown never cleared and
        // our hover "moved"s would replay as a phantom drag. A "cancelled"
        // on every (re)connect heals that; with nothing pressed the sender
        // ignores it outright.
        view.reconnectCancellable = receiver.$connected
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak view] _ in view?.healSenderDragState() }
        return view
    }

    func updateNSView(_ nsView: ReceiverVideoView, context: Context) {
        // videoSize arrives after the format description — re-fit the layers.
        nsView.needsLayout = true
    }
}

final class ReceiverVideoView: NSView {
    weak var receiver: DisplayReceiver?
    var reconnectCancellable: AnyCancellable?
    private weak var videoLayer: AVSampleBufferDisplayLayer?
    private weak var metalLayer: CAMetalLayer?
    private var lastDisplayProfileDescription = ""

    // Top-left-origin coordinates, matching the wire protocol (and making the
    // layer tree behave like UIKit's, so the cursor code mirrors iOS).
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
    private var hardwarePointerOverVideo = false
    private var hardwareCursor = NSCursor.arrow
    private var hardwareCursorSourceImage: NSImage?
    private var hardwareCursorAnchor = CGPoint.zero
    private var hardwareCursorPointSize = CGSize.zero
    private var nativeCursorHiddenForInactivity = true
    private var nativeCursorHideWorkItem: DispatchWorkItem?
    private let nativeCursorHideDelay: TimeInterval = 0.30
    // While the hardware pointer is over this receiver's video, its AppKit
    // coordinates are the freshest possible cursor position. Do not let the
    // sender's round-trip echo (which is necessarily a few samples older)
    // overwrite them and create a saw-tooth path on diagonal movement.
    private var localCursorOverride = false
    private var lastLocalCursorEventAt = Date.distantPast
    // The receiver's native pointer must not be replaced by a delayed sender
    // echo during a brief AppKit event gap. A quarter second still hands the
    // surface back quickly when the sending Mac's physical mouse takes over.
    private let localCursorOverrideGrace: TimeInterval = 0.25

    // Fully transparent cursor shown while the pointer is over the video —
    // the sender's echoed sprite replaces it.
    private static let blankCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        displayLayer.removeFromSuperlayer()
        if let renderer = receiver?.metalRenderer {
            let metal = renderer.metalLayer
            metal.removeFromSuperlayer()
            metal.frame = bounds
            metalLayer = metal
            videoLayer = nil
            layer?.insertSublayer(metal, at: 0)
            layer?.addSublayer(cursorLayer)
            Log.info("video view attached Metal surface")
        } else {
            displayLayer.frame = bounds
            videoLayer = displayLayer
            metalLayer = nil
            layer?.insertSublayer(displayLayer, at: 0)
            Log.info("video view attached AVSampleBufferDisplayLayer fallback")
        }
        if metalLayer == nil {
            cursorLayer.removeFromSuperlayer()
        }
        syncContentsScale()
        needsLayout = true
    }

    // Unlike iOS, macOS layers default to contentsScale 1.0 — the compositor
    // would render the video into a point-sized (half-resolution) backing on
    // Retina panels. Track the window's actual backing scale.
    private func syncContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        let changed = layer?.contentsScale != scale
            || videoLayer?.contentsScale != scale
            || metalLayer?.contentsScale != scale
            || cursorLayer.contentsScale != scale
        layer?.contentsScale = scale
        videoLayer?.contentsScale = scale
        metalLayer?.contentsScale = scale
        cursorLayer.contentsScale = scale
        if changed { Log.info("contentsScale -> \(scale)") }
    }

    /// CAMetalLayer receives the decoded frame's actual source profile, then
    /// Core Animation color-matches it to this screen's active ICC profile.
    private func logDisplayColorProfile() {
        guard let window, let screen = window.screen else { return }
        let displaySpace = screen.colorSpace
        let windowSpace = window.colorSpace
        let displayName = displaySpace?.localizedName ?? "unnamed"
        let windowName = windowSpace?.localizedName ?? "unnamed"
        let displayBytes = displaySpace?.iccProfileData?.count ?? 0
        let windowBytes = windowSpace?.iccProfileData?.count ?? 0
        let matches = displaySpace?.iccProfileData == windowSpace?.iccProfileData
        let description = "\(windowName)|\(windowBytes)|\(displayName)|"
            + "\(displayBytes)|\(matches)"
        guard description != lastDisplayProfileDescription else { return }
        lastDisplayProfileDescription = description
        Log.info("ColorSync target: window=\(windowName) ICC=\(windowBytes)B "
            + "display=\(displayName) ICC=\(displayBytes)B match=\(matches)")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncContentsScale()
        logDisplayColorProfile()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncContentsScale()
        logDisplayColorProfile()
    }

    // MARK: - Layout

    private var lastLoggedLayout = ""

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let metalLayer {
            // Metal draws a full quad, so aspect-fit by sizing its layer.
            metalLayer.frame = videoRect() ?? bounds
        } else {
            // AVSBDL fallback aspect-fits internally (videoGravity).
            videoLayer?.frame = bounds
        }
        updateCursorLayout()
        rebuildHardwareCursor()
        CATransaction.commit()
        let video = receiver?.videoSize ?? .zero
        let line = "layout: bounds=\(Int(bounds.width))x\(Int(bounds.height))"
            + " video=\(Int(video.width))x\(Int(video.height))"
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

    // MARK: - Cursor echo

    func moveCursor(x: Double, y: Double, visible: Bool) {
        if localCursorOverride {
            // Ignore only echoes that overlap active receiver-side movement.
            // Once local events stop, a different sender-side coordinate is
            // allowed to take ownership so the sending Mac's physical mouse
            // remains visible on the virtual display.
            guard Date().timeIntervalSince(lastLocalCursorEventAt)
                    > localCursorOverrideGrace else { return }
            localCursorOverride = false
            nativeCursorHideWorkItem?.cancel()
            nativeCursorHideWorkItem = nil
            nativeCursorHiddenForInactivity = true
            receiver?.sendPointerPresence(inside: false)
            if hardwarePointerOverVideo {
                Self.blankCursor.set()
            }
        }
        let wasVisible = cursorVisible && !cursorLayer.isHidden
        let oldPresentationPosition = cursorLayer.presentation()?.position
            ?? cursorLayer.position
        cursorNorm = CGPoint(x: x, y: y)
        cursorVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible || cursorLayer.contents == nil
        updateCursorLayout()
        CATransaction.commit()

        // UDP samples can arrive between the receiver's 60Hz display ticks.
        // A tiny, linear, one-sample interpolation lets Core Animation fill
        // that gap without adding the floaty lag of conventional smoothing.
        // Large jumps and visibility transitions still snap immediately.
        if visible, wasVisible, cursorLayer.contents != nil {
            let target = cursorLayer.position
            let distance = hypot(target.x - oldPresentationPosition.x,
                                 target.y - oldPresentationPosition.y)
            if distance > 0.25, distance < max(bounds.width, bounds.height) * 0.08 {
                let animation = CABasicAnimation(keyPath: "position")
                animation.fromValue = NSValue(point: oldPresentationPosition)
                animation.toValue = NSValue(point: target)
                animation.duration = 1.0 / 120.0
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                cursorLayer.add(animation, forKey: "remoteCursorPosition")
            } else {
                cursorLayer.removeAnimation(forKey: "remoteCursorPosition")
            }
        } else {
            cursorLayer.removeAnimation(forKey: "remoteCursorPosition")
        }
    }

    func setCursorSprite(_ image: NSImage, anchor: CGPoint, normSize: CGSize) {
        hardwareCursorSourceImage = image
        hardwareCursorAnchor = anchor
        hardwareCursorPointSize = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cursorLayer.anchorPoint = anchor
        cursorNormSize = normSize
        cursorLayer.isHidden = !cursorVisible
        updateCursorLayout()
        rebuildHardwareCursor()
        CATransaction.commit()
    }

    /// PNG decoding reports Retina backing pixels as NSImage points on some
    /// macOS versions, making a normal 32pt cursor appear around 64pt. The
    /// wire already carries the authoritative cursor size normalized against
    /// the sender display, so reconstruct its point size from our fitted video
    /// rect instead of trusting PNG metadata.
    private func rebuildHardwareCursor() {
        guard let source = hardwareCursorSourceImage else { return }
        let desired: CGSize
        if let rect = videoRect(), cursorNormSize != .zero {
            desired = CGSize(width: cursorNormSize.width * rect.width,
                             height: cursorNormSize.height * rect.height)
        } else {
            let scale = window?.backingScaleFactor ?? 2
            desired = CGSize(width: source.size.width / scale,
                             height: source.size.height / scale)
        }
        guard desired.width >= 1, desired.height >= 1,
              desired.width <= 256, desired.height <= 256,
              desired != hardwareCursorPointSize else { return }
        guard let sizedImage = source.copy() as? NSImage else { return }
        sizedImage.size = desired
        let hotSpot = NSPoint(x: hardwareCursorAnchor.x * desired.width,
                              y: hardwareCursorAnchor.y * desired.height)
        hardwareCursor = NSCursor(image: sizedImage, hotSpot: hotSpot)
        hardwareCursorPointSize = desired
        if localCursorOverride, hardwarePointerOverVideo,
           !nativeCursorHiddenForInactivity {
            hardwareCursor.set()
        }
    }

    private func updateCursorLayout() {
        guard let rect = videoRect(), cursorNormSize != .zero else { return }
        cursorLayer.bounds = CGRect(x: 0, y: 0,
                                    width: cursorNormSize.width * rect.width,
                                    height: cursorNormSize.height * rect.height)
        cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                       y: rect.minY + cursorNorm.y * rect.height)
    }

    // MARK: - Tracking (hover + native local cursor)

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                      .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if videoRect()?.contains(point) == true {
            hardwarePointerOverVideo = true
            if localCursorOverride, !nativeCursorHiddenForInactivity {
                hardwareCursor.set()
            } else {
                Self.blankCursor.set()
            }
        } else {
            hardwarePointerOverVideo = false
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        endLocalCursorOverride()
        NSCursor.arrow.set()
    }

    // Teardown (stream ended) fires no mouseExited for the dying tracking
    // area — restore the arrow or the idle view inherits an invisible cursor.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            nativeCursorHideWorkItem?.cancel()
            nativeCursorHideWorkItem = nil
            nativeCursorHiddenForInactivity = true
            hardwarePointerOverVideo = false
            NSCursor.arrow.set()
        }
    }

    // First click on an inactive window should already register on the
    // extended desktop, like a real monitor would.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Mouse -> wire

    // The video is aspect-fit inside the view; map view coords into the
    // displayed video rect and normalize to [0,1] (origin top-left — the
    // view is flipped, so location(in:) already is).
    private func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
        guard let rect = videoRect() else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)
    private var isMouseDown = false

    private func beginLocalCursorOverride(x: Double, y: Double) {
        lastLocalCursorEventAt = Date()
        hardwarePointerOverVideo = true
        nativeCursorHiddenForInactivity = false
        if !localCursorOverride {
            localCursorOverride = true
            receiver?.sendPointerPresence(inside: true)
        }
        cursorNorm = CGPoint(x: x, y: y)
        cursorVisible = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Receiver-local movement uses the WindowServer hardware pointer.
        // Keep the sprite layer exclusively for the sending Mac's pointer.
        cursorLayer.isHidden = true
        CATransaction.commit()
        hardwareCursor.set()
        scheduleNativeCursorHide()
    }

    private func scheduleNativeCursorHide() {
        nativeCursorHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.localCursorOverride,
                  self.hardwarePointerOverVideo,
                  Date().timeIntervalSince(self.lastLocalCursorEventAt)
                    >= self.nativeCursorHideDelay else { return }
            self.nativeCursorHiddenForInactivity = true
            self.cursorVisible = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.cursorLayer.isHidden = true
            CATransaction.commit()
            Self.blankCursor.set()
        }
        nativeCursorHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + nativeCursorHideDelay,
                                      execute: work)
    }

    private func endLocalCursorOverride() {
        let wasLocal = localCursorOverride
        nativeCursorHideWorkItem?.cancel()
        nativeCursorHideWorkItem = nil
        nativeCursorHiddenForInactivity = true
        localCursorOverride = false
        hardwarePointerOverVideo = false
        cursorVisible = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = true
        CATransaction.commit()
        if wasLocal {
            receiver?.sendPointerPresence(inside: false)
        }
    }

    func healSenderDragState() {
        receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
    }

    private func send(_ phase: String, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Passive hover in the letterbox bars stays local: clamping it would
        // drag the sender's cursor along the video edge. Clicks and drags
        // keep the clamp (iOS parity — a drag may legitimately leave the
        // video and still needs its moved/ended delivered).
        if phase == "moved", !isMouseDown,
           let rect = videoRect(), !rect.contains(point) {
            endLocalCursorOverride()
            NSCursor.arrow.set()
            return
        }
        guard let norm = normalized(point) else {
            // videoSize can blip away mid-drag (format renegotiation) — still
            // release the button, or the sender's cursor stays stuck dragging.
            if phase == "ended" || phase == "cancelled" {
                receiver?.sendTouch(phase: phase, x: lastNorm.x, y: lastNorm.y)
            }
            return
        }
        lastNorm = norm
        beginLocalCursorOverride(x: norm.x, y: norm.y)
        receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
    }

    override func mouseDown(with event: NSEvent) {
        isMouseDown = true
        send("began", event)
    }
    override func mouseDragged(with event: NSEvent) { send("moved", event) }
    override func mouseUp(with event: NSEvent) {
        send("ended", event)
        isMouseDown = false
    }
    // Hover: "moved" with no active press injects a pure cursor move.
    override func mouseMoved(with event: NSEvent) { send("moved", event) }

    override func scrollWheel(with event: NSEvent) {
        guard let video = receiver?.videoSize, video != .zero,
              bounds.width > 0, bounds.height > 0 else { return }
        // Precise deltas (trackpad/Magic Mouse) are in points; line-based
        // wheel clicks get a conventional points-per-line factor.
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        // Deltas in video pixels. AppKit's scrollingDelta sign convention
        // matches the wire's natural-scrolling sign (both mean "content
        // moves this way"), so pass it straight through.
        let dx = event.scrollingDeltaX * factor / scale
        let dy = event.scrollingDeltaY * factor / scale
        guard dx != 0 || dy != 0 else { return }
        receiver?.sendScroll(dx: dx, dy: dy)
    }
}
