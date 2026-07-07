// VideoView.swift — UIKit host for the video display layer + touch/pointer
// input. Ported from the modern app's embedded VideoLayerView.VideoView;
// the SwiftUI UIViewRepresentable wrapper is gone — RootViewController adds
// this directly as a subview.

import UIKit
import AVFoundation

final class VideoView: UIView {
    private weak var receiver: PhoneReceiverLegacy?

    private let cursorLayer: CALayer = {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 10
        layer.actions = ["position": NSNull(), "contents": NSNull(),
                         "bounds": NSNull(), "hidden": NSNull()]
        return layer
    }()
    private var cursorNormSize = CGSize.zero
    private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
    private var cursorVisible = false

    init(receiver: PhoneReceiverLegacy) {
        self.receiver = receiver
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true

        receiver.displayLayer.frame = bounds
        layer.addSublayer(receiver.displayLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(didTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)

        receiver.onCursor = { [weak self] x, y, visible in
            self?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak self] image, anchor, normSize in
            self?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers?.first?.frame = bounds
        if cursorLayer.superlayer == nil { layer.addSublayer(cursorLayer) }
        updateCursorLayout()
        CATransaction.commit()
    }

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

    func setCursorSprite(_ image: UIImage, anchor: CGPoint, normSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image.cgImage
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

    private func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
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

    private var twoFingerActive = false
    private var lastPan = CGPoint.zero
    private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)

    @objc private func didTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard let video = receiver?.videoSize, video != .zero else { return }
        switch recognizer.state {
        case .began:
            twoFingerActive = true
            lastPan = .zero
        case .changed:
            let t = recognizer.translation(in: self)
            let scale = min(bounds.width / video.width, bounds.height / video.height)
            receiver?.sendScroll(dx: (t.x - lastPan.x) / scale, dy: (t.y - lastPan.y) / scale)
            lastPan = t
        default:
            twoFingerActive = false
        }
    }

    private func send(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
        if twoFingerActive || (event?.allTouches?.count ?? 1) > 1 {
            if phase != "began" {
                receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
            }
            return
        }
        guard let touch = touches.first,
              let norm = normalized(touch.location(in: self)) else { return }
        lastNorm = norm
        if phase == "moved", let event {
            for t in event.coalescedTouches(for: touch) ?? [touch] {
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send("began", touches, event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send("moved", touches, event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send("ended", touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send("cancelled", touches, event) }
}
