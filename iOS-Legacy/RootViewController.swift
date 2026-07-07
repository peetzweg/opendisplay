import UIKit
import AVFoundation

final class RootViewController: UIViewController, PhoneReceiverLegacyDelegate {
    private let receiver = PhoneReceiverLegacy(displayLayer: AVSampleBufferDisplayLayer())
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        // iOS 12 has no dark mode, so there's no dynamic .systemBackground —
        // .white is its fixed light-appearance equivalent.
        view.backgroundColor = .white
        statusLabel.textAlignment = .center
        statusLabel.frame = view.bounds
        statusLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(statusLabel)
        receiver.delegate = self
        receiver.start(port: 9000)
    }

    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didUpdateStatus status: String) {
        statusLabel.text = status
    }
    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didChangeConnected connected: Bool) {}
    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didUpdateVideoSize size: CGSize) {}
}
