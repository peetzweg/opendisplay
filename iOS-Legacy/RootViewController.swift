// RootViewController.swift — single-screen host: idle screen while waiting
// for the Mac, swaps to the video view once a stream is active. Ported from
// the modern app's ReceiverScreen/IdleView (SwiftUI removed).

import UIKit
import AVFoundation

let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
let macAppURL = URL(string: "https://peetzweg.github.io/opendisplay/")!

// iOS 13 introduced dynamic system/label colors for Dark Mode
// (.systemBackground, .systemGreen, .systemOrange, .secondaryLabel,
// .tertiaryLabel). iOS 12 has no dark mode, so there's no dynamic
// counterpart to weigh — these are the fixed light-appearance values
// Apple's HIG documents for each.
private extension UIColor {
    static let legacySystemBackground = UIColor.white
    static let legacySystemGreen = UIColor(red: 52/255, green: 199/255, blue: 89/255, alpha: 1)
    static let legacySystemOrange = UIColor(red: 255/255, green: 149/255, blue: 0/255, alpha: 1)
    static let legacySecondaryLabel = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.6)
    static let legacyTertiaryLabel = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.3)
}

final class RootViewController: UIViewController, PhoneReceiverLegacyDelegate {

    let receiver = PhoneReceiverLegacy(displayLayer: AVSampleBufferDisplayLayer())
    private var videoView: VideoView?
    private let idleContainer = UIView()
    private let statusDot = UIView()
    private let statusLabel = UILabel()

    private var isStreaming: Bool {
        receiver.connected && receiver.videoSize != .zero
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .legacySystemBackground
        receiver.delegate = self

        let native = UIScreen.main.nativeBounds.size
        receiver.setNativePanel(long: Int(max(native.width, native.height)),
                                 short: Int(min(native.width, native.height)),
                                 scale: Double(UIScreen.main.nativeScale))
        let savedName = UserDefaults.standard.string(forKey: "deviceName")
        receiver.setServiceName((savedName?.isEmpty == false) ? savedName! : UIDevice.current.name)

        buildIdleView()
        refresh()

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                                name: UIApplication.didBecomeActiveNotification, object: nil)
        receiver.start(port: 9000)
        updateOrientation(size: view.bounds.size)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        updateOrientation(size: size)
    }

    private func updateOrientation(size: CGSize) {
        receiver.setOrientation(portrait: size.height > size.width)
    }

    @objc private func appDidBecomeActive() {
        receiver.ensureListening()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            presentSettings()
        }
    }

    override var prefersStatusBarHidden: Bool { isStreaming }

    // MARK: - PhoneReceiverLegacyDelegate

    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didUpdateStatus status: String) {
        statusLabel.text = status
    }

    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didChangeConnected connected: Bool) {
        statusDot.backgroundColor = connected ? .legacySystemGreen : .legacySystemOrange
        refresh()
    }

    func phoneReceiver(_ receiver: PhoneReceiverLegacy, didUpdateVideoSize size: CGSize) {
        refresh()
    }

    // MARK: - View switching

    private func refresh() {
        if isStreaming { showVideo() } else { showIdle() }
        setNeedsStatusBarAppearanceUpdate()
    }

    private func showVideo() {
        guard videoView == nil else { return }
        let video = VideoView(receiver: receiver)
        video.frame = view.bounds
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(video)
        videoView = video
        idleContainer.isHidden = true
    }

    private func showIdle() {
        videoView?.removeFromSuperview()
        videoView = nil
        idleContainer.isHidden = false
    }

    // MARK: - Idle screen

    private func buildIdleView() {
        idleContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(idleContainer)
        NSLayoutConstraint.activate([
            idleContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            idleContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            idleContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        idleContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: idleContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: idleContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: idleContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: idleContainer.trailingAnchor),
        ])

        let logoView = UIImageView(image: UIImage(named: "AppLogo"))
        logoView.contentMode = .scaleAspectFit
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.widthAnchor.constraint(equalToConstant: 96).isActive = true
        logoView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        stack.addArrangedSubview(logoView)

        let title = UILabel()
        title.text = "OpenDisplay"
        title.font = .boldSystemFont(ofSize: 28)
        stack.addArrangedSubview(title)

        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center
        statusDot.layer.cornerRadius = 4
        statusDot.backgroundColor = .legacySystemOrange
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        statusLabel.text = "Starting…"
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textColor = .legacySecondaryLabel
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(statusRow)

        let instructions = UILabel()
        instructions.numberOfLines = 0
        instructions.textAlignment = .center
        instructions.font = .preferredFont(forTextStyle: .subheadline)
        instructions.text = "Plug in the USB cable and start the Mac app, or choose this \(deviceKind) under WiFi in the Mac app. Keep this app open — streaming starts automatically."
        stack.addArrangedSubview(instructions)

        let settingsButton = UIButton(type: .system)
        settingsButton.setTitle("Settings & Help", for: .normal)
        settingsButton.addTarget(self, action: #selector(presentSettings), for: .touchUpInside)
        stack.addArrangedSubview(settingsButton)

        let tip = UILabel()
        tip.text = "Tip: shake the \(deviceKind) to open settings anytime"
        tip.font = .preferredFont(forTextStyle: .footnote)
        tip.textColor = .legacyTertiaryLabel
        stack.addArrangedSubview(tip)
    }

    @objc func presentSettings() {
        let settings = SettingsViewController(receiver: receiver)
        let nav = UINavigationController(rootViewController: settings)
        present(nav, animated: true)
    }
}
