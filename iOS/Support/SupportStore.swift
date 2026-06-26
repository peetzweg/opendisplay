import Foundation
import StoreKit

/// StoreKit 2 manager for the voluntary "support / tip" in-app purchases.
///
/// These purchases **unlock nothing functionally** — they are purely a way for
/// users who enjoy OpenSidecar to support its development through Apple's
/// In-App Purchase system. On a successful purchase we show a transient
/// thank-you; there is no feature gating anywhere in the app.
///
/// ## App Store Connect prerequisite
/// The product identifiers below must exist in App Store Connect before real
/// purchases work (until then `Product.products(for:)` returns an empty list,
/// which `SupportView` surfaces as a friendly "not available yet" message).
/// Create:
///   - `com.peetzweg.opensidecar.ios.support.tip.2`   — Consumable (~$2)
///   - `com.peetzweg.opensidecar.ios.support.tip.10`  — Consumable (~$10)
///   - `com.peetzweg.opensidecar.ios.support.monthly` — Auto-renewable subscription (~$2 / month)
///
/// If you name them differently in App Store Connect, update `SupportProduct`
/// below to match. The bundle-id prefix (`com.peetzweg.opensidecar.ios`)
/// mirrors `PRODUCT_BUNDLE_IDENTIFIER` for the iOS target in `project.yml`.
///
/// For local testing without App Store Connect, run the app from the
/// `OpenSidecariOS` scheme with the bundled `Support.storekit` configuration
/// selected (Edit Scheme → Run → Options → StoreKit Configuration).
enum SupportProduct: String, CaseIterable {
    case tipSmall = "com.peetzweg.opensidecar.ios.support.tip.2"
    case tipLarge = "com.peetzweg.opensidecar.ios.support.tip.10"
    case monthly  = "com.peetzweg.opensidecar.ios.support.monthly"

    /// All product IDs to request from StoreKit, in display order.
    static var allIDs: [String] { allCases.map(\.rawValue) }

    /// Short fallback label used only if a product can't be loaded.
    var fallbackTitle: String {
        switch self {
        case .tipSmall: return "Small tip"
        case .tipLarge: return "Generous tip"
        case .monthly:  return "Monthly support"
        }
    }
}

/// Error thrown when a StoreKit transaction fails verification.
enum SupportStoreError: Error {
    case failedVerification
}

@MainActor
final class SupportStore: ObservableObject {
    /// Loaded products, ordered: small tip, large tip, then subscription.
    @Published private(set) var products: [Product] = []
    /// True while the initial product load is in flight.
    @Published private(set) var isLoadingProducts = false
    /// The product ID currently being purchased (drives per-row spinners).
    @Published private(set) var purchasingProductID: String?
    /// Set after a successful purchase so the UI can show a thank-you.
    @Published var thankYouShown = false
    /// User-facing message when products can't be loaded (expected until
    /// App Store Connect is configured).
    @Published private(set) var loadError: String?
    /// Whether the user currently holds the support subscription. Surfaced for
    /// information only — nothing in the app is gated on it.
    @Published private(set) var hasActiveSubscription = false

    /// Convenience: the products that are consumable tips.
    var tipProducts: [Product] {
        products.filter { $0.type == .consumable }
    }

    /// Convenience: the auto-renewable subscription product, if loaded.
    var subscriptionProduct: Product? {
        products.first { $0.type == .autoRenewable }
    }

    /// Load the support products from the App Store (or local .storekit file).
    func loadProducts() async {
        isLoadingProducts = true
        loadError = nil
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: SupportProduct.allIDs)
            // Keep the order defined in SupportProduct.allIDs.
            let order = SupportProduct.allIDs
            products = loaded.sorted {
                (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
            }
            if products.isEmpty {
                loadError = "Support options aren't available right now. Please try again later."
            }
            await refreshSubscriptionStatus()
        } catch {
            loadError = "Couldn't load support options. Please try again later."
            Log.info("SupportStore: failed to load products: \(error.localizedDescription)")
        }
    }

    /// Attempt to purchase a product. Handles success / user-cancel / pending.
    func purchase(_ product: Product) async {
        purchasingProductID = product.id
        defer { purchasingProductID = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                // Nothing to unlock — just acknowledge and finish so the
                // payment completes and StoreKit stops re-delivering it.
                await transaction.finish()
                thankYouShown = true
                await refreshSubscriptionStatus()
            case .userCancelled:
                // No-op: the user backed out. Don't show an error.
                break
            case .pending:
                // e.g. Ask to Buy / SCA. The transaction will arrive later via
                // Transaction.updates; nothing for us to unlock so we simply
                // don't show a thank-you yet.
                break
            @unknown default:
                break
            }
        } catch {
            Log.info("SupportStore: purchase failed: \(error.localizedDescription)")
        }
    }

    /// Verify a StoreKit transaction result, unwrapping the signed payload.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw SupportStoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    /// Refresh whether the user holds the support subscription. Informational
    /// only — no functionality depends on this.
    func refreshSubscriptionStatus() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == SupportProduct.monthly.rawValue,
               transaction.revocationDate == nil {
                active = true
            }
        }
        hasActiveSubscription = active
    }

    /// Listen for transactions that arrive outside an explicit purchase call
    /// (e.g. a previously pending "Ask to Buy" being approved, or renewals).
    /// Call once from the view's `.task`. Returns a Task the caller can cancel.
    func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.refreshSubscriptionStatus()
                }
            }
        }
    }
}
