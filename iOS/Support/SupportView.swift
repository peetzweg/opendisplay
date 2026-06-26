import SwiftUI
import StoreKit

/// Voluntary "support OpenSidecar" screen. Lists the tip / subscription tiers
/// loaded from StoreKit. Buying any of them **unlocks nothing** — it's purely a
/// thank-you channel for users who want to chip in. Prices are taken from the
/// loaded `Product.displayPrice` (localized by App Store / .storekit), never
/// hardcoded.
struct SupportView: View {
    @StateObject private var store = SupportStore()
    @State private var updatesTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Support OpenSidecar")
                        .font(.title2.bold())
                    Text("OpenSidecar is free and open source, with no account and no subscription required to use it. If it's saved you the price of a second monitor — or you just want to keep it going — a small voluntary tip helps fund development.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("These purchases unlock nothing — every feature stays free for everyone. They're just a thank-you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if store.isLoadingProducts {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading support options…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if store.products.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Support options aren't available right now.", systemImage: "heart.slash")
                            .font(.subheadline)
                        Text(store.loadError ?? "Please try again later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await store.loadProducts() }
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                if !store.tipProducts.isEmpty {
                    Section {
                        ForEach(store.tipProducts) { product in
                            SupportTierRow(product: product,
                                           isPurchasing: store.purchasingProductID == product.id) {
                                Task { await store.purchase(product) }
                            }
                        }
                    } header: {
                        Text("One-time tip")
                    } footer: {
                        Text("A single thank-you. Tip as many times as you like.")
                    }
                }

                if let subscription = store.subscriptionProduct {
                    Section {
                        SupportTierRow(product: subscription,
                                       isPurchasing: store.purchasingProductID == subscription.id) {
                            Task { await store.purchase(subscription) }
                        }
                    } header: {
                        Text("Monthly support")
                    } footer: {
                        Text(store.hasActiveSubscription
                             ? "You're currently supporting OpenSidecar monthly — thank you! Manage or cancel anytime in the App Store. Auto-renews until cancelled."
                             : "Recurring monthly support. Auto-renews until cancelled; manage anytime in the App Store.")
                    }
                }
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            updatesTask = store.listenForTransactions()
            await store.loadProducts()
        }
        .onDisappear { updatesTask?.cancel() }
        .alert("Thank you! ♥", isPresented: $store.thankYouShown) {
            Button("You're welcome", role: .cancel) { }
        } message: {
            Text("Your support means a lot and helps keep OpenSidecar free and open source.")
        }
    }
}

/// A single purchasable tier: title, description, price, and a buy button.
private struct SupportTierRow: View {
    let product: Product
    let isPurchasing: Bool
    let onBuy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName)
                    .font(.body.weight(.medium))
                if !product.description.isEmpty {
                    Text(product.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button(action: onBuy) {
                if isPurchasing {
                    ProgressView()
                        .frame(minWidth: 64)
                } else {
                    Text(product.displayPrice)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 64)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPurchasing)
        }
        .padding(.vertical, 2)
    }
}
