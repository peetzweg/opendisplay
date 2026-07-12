import SwiftUI

// `AppStore` (the App Store identity + deep link) lives in Shared/AppStore.swift
// so the Mac can reference the same link when it asks the phone to update.

// MARK: - Peer-driven update signals (issue #132)

/// What the connected Mac (or its absence) tells us about compatibility. Fed
/// into the same gate as the remote-config check so there is one update UI.
enum PeerUpdateSignal: Equatable {
    case updateIPhone(message: String, storeURL: URL)   // Mac sent `updateRequired`
    case updateMac(message: String)                     // Mac's pv is below our floor
}

// MARK: - Version gate (issue #135)

/// Connection-independent update lever. On launch the app fetches a small
/// policy file we host on GitHub Pages next to the Sparkle appcast and compares
/// its own version against it. This is the ONLY mechanism that can reach an
/// install that never connects to an updated Mac (e.g. the large tail still on
/// an old release) — the peer-driven `updateRequired` path (issue #132) can't.
///
/// Privacy: the only egress is a single unauthenticated GET of a static file,
/// carrying no identifiers. It fails open — any network or parse error, or a
/// missing/dormant floor, leaves the gate closed so a Pages outage can never
/// brick the app.
@MainActor
final class VersionGate: ObservableObject {
    struct Update: Identifiable, Equatable {
        let message: String
        let url: URL
        // Content-derived so re-applying the same signal (e.g. the phone
        // re-sends hello on rotation → Mac re-sends its reply) keeps a stable
        // identity and doesn't make `fullScreenCover(item:)` re-present.
        var id: String { url.absoluteString + "\n" + message }
    }

    enum Status: Equatable {
        case ok
        case recommended(Update)   // soft, dismissible nag
        case required(Update)      // hard floor — blocking, non-dismissible
    }

    /// The effective gate: the more severe of the remote-config result and the
    /// peer signal.
    @Published private(set) var status: Status = .ok

    // The two independent inputs, merged by `recompute()`.
    private var remoteStatus: Status = .ok
    private var peerStatus: Status = .ok

    private let manifestURL = URL(string: "https://opendisplay.app/ios-version.json")!

    /// The running app's marketing version. Local/dev builds ship "0.0.0"
    /// (the project.yml default), which we treat as "skip the gate".
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func check() async {
        let current = currentVersion
        guard current != "0.0.0" else { return }   // dev build — never gate

        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 8
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return }   // fail open

        let policy = manifest.ios
        let url = policy.storeURL.flatMap { URL(string: $0) } ?? AppStore.updateURL

        if let floor = policy.hardMinimumVersion, isVersion(current, olderThan: floor) {
            remoteStatus = .required(Update(message: policy.message ?? Self.requiredFallback, url: url))
        } else if let want = policy.recommendedVersion, isVersion(current, olderThan: want) {
            remoteStatus = .recommended(Update(message: policy.message ?? Self.recommendedFallback, url: url))
        } else {
            remoteStatus = .ok
        }
        recompute()
    }

    /// Fold in what the connected Mac told us. `updateIPhone` is a hard gate
    /// (the Mac refuses this pairing); `updateMac` is a soft nag pointing at the
    /// Mac app download, since the fix is on the other device. Passing `nil`
    /// clears the peer signal (e.g. on disconnect).
    func applyPeer(_ signal: PeerUpdateSignal?) {
        switch signal {
        case let .updateIPhone(message, storeURL):
            peerStatus = .required(Update(message: message, url: storeURL))
        case let .updateMac(message):
            peerStatus = .recommended(Update(message: message, url: macAppURL))
        case nil:
            peerStatus = .ok
        }
        recompute()
    }

    private func recompute() {
        status = severity(peerStatus) >= severity(remoteStatus) ? peerStatus : remoteStatus
    }

    private func severity(_ s: Status) -> Int {
        switch s {
        case .ok: return 0
        case .recommended: return 1
        case .required: return 2
        }
    }

    // MARK: Policy file shape

    private struct Manifest: Decodable {
        struct Policy: Decodable {
            let hardMinimumVersion: String?
            let recommendedVersion: String?
            let storeURL: String?
            let message: String?
        }
        let ios: Policy
    }

    private static let requiredFallback =
        "This version of OpenDisplay is no longer supported. Update from the App Store to keep using your second display."
    private static let recommendedFallback =
        "A newer version of OpenDisplay is available."
}

/// Numeric dotted-version compare (e.g. "0.10.0" older than "0.11.0"). Missing
/// components count as 0; non-numeric suffixes are ignored so a pre-release tag
/// never blocks the compare.
func isVersion(_ a: String, olderThan b: String) -> Bool {
    let lhs = versionComponents(a), rhs = versionComponents(b)
    for i in 0..<max(lhs.count, rhs.count) {
        let x = i < lhs.count ? lhs[i] : 0
        let y = i < rhs.count ? rhs[i] : 0
        if x != y { return x < y }
    }
    return false
}

private func versionComponents(_ s: String) -> [Int] {
    s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
}

// MARK: - Blocking update screen

/// Full-screen, non-dismissible gate shown when the install is below the force
/// floor. Modeled on `OnboardingView`; the only action is opening the App Store.
struct UpdateRequiredView: View {
    let update: VersionGate.Update

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 10) {
                Text("Update required")
                    .font(.title2.bold())
                Text(update.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                UIApplication.shared.open(update.url)
            } label: {
                Label("Update on the App Store", systemImage: "arrow.down.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(32)
        .interactiveDismissDisabled()   // belt-and-suspenders; no dismiss affordance anyway
    }
}
