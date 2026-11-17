import AppKit
import SwiftUI

@MainActor
final class MacBrightnessHUDPresenter {
    private final class Model: ObservableObject {
        @Published var brightness: Double?
    }

    private struct ContainerView: View {
        @ObservedObject var model: Model

        var body: some View {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .brightnessHUD($model.brightness)
        }
    }

    private let model = Model()
    private var hostingView: NSHostingView<ContainerView>?

    /// Shows or updates the HUD over the specified NSView
    func show(brightness: Double, in parentView: NSView) {
        let host = ensureHostingView(in: parentView)
        if host.superview !== parentView {
            host.removeFromSuperview()
            attach(host, to: parentView)
        }

        if model.brightness == nil {
            withAnimation(.easeOut(duration: 0.15)) {
                model.brightness = brightness
            }
        } else {
            model.brightness = brightness
        }
    }

    private func ensureHostingView(in parentView: NSView) -> NSHostingView<ContainerView> {
        if let hostingView {
            return hostingView
        }
        let host = NSHostingView(rootView: ContainerView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        attach(host, to: parentView)
        self.hostingView = host
        return host
    }

    private func attach(_ host: NSHostingView<ContainerView>, to parentView: NSView) {
        parentView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: parentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: parentView.bottomAnchor)
        ])
    }

    /// Removes the HUD from its superview and releases the hosting view.
    /// Call this when the parent view or window is being torn down.
    func remove() {
        hostingView?.removeFromSuperview()
        hostingView = nil
    }

    deinit {
        remove()
    }
}
