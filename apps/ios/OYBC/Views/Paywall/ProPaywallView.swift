import SwiftUI
import RevenueCat

/// The Pro paywall (docs/MONETIZATION.md). Renders the current RevenueCat
/// offering (monthly / yearly / lifetime + the 7-day trial) via StoreKit, with
/// Restore Purchases and Terms/Privacy links (App Store 3.1.2). Purchasing
/// requires a real account — a guest is routed through the existing upgrade sheet
/// first, after which the plans become purchasable.
struct ProPaywallView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var entitlementService: EntitlementService
    @Environment(\.dismiss) private var dismiss

    @State private var packages: [Package]?
    @State private var busyProductId: String?
    @State private var errorMessage: String?
    @State private var isRestoring = false
    @State private var showUpgrade = false

    private static let termsURL = URL(string: "https://oybc.com/terms")!
    private static let privacyURL = URL(string: "https://oybc.com/privacy")!

    private let benefits = [
        "Unlimited boards",
        "Recurring & core boards (daily, weekly, monthly, yearly)",
        "Achievement & compound tasks",
    ]

    var body: some View {
        ZStack {
            RisoPaperBackground().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if entitlementService.isPro {
                        proState
                    } else {
                        benefitsList
                        if authService.isAnonymous {
                            Text("Create a free account to subscribe — your boards come with you.")
                                .font(.risoBody(13, .regular))
                                .foregroundStyle(Color.risoMuted)
                        }
                        if let errorMessage {
                            banner(errorMessage)
                        }
                        plans
                        restoreButton
                        legal
                    }
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .task { await loadOfferings() }
        .sheet(isPresented: $showUpgrade) { UpgradeAccountSheet().environmentObject(authService) }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("OYBC Pro")
                    .font(.risoBody(12, .bold))
                    .tracking(1)
                    .foregroundStyle(Color.risoMuted)
                Text(entitlementService.isPro ? "You're on Pro 🎉" : "Unlock everything.")
                    .font(.risoHead(24, .extraBold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.risoInk)
            }
            Spacer()
            SwiftUI.Button("Close") { dismiss() }
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
        }
        .padding(.top, 24)
    }

    private var proState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Thanks for supporting OYBC — every Pro feature is unlocked on all your devices.")
                .font(.risoBody(14, .regular))
                .foregroundStyle(Color.risoInk)
                .fixedSize(horizontal: false, vertical: true)
            RisoButton(title: "Done", kind: .primary, fullWidth: true) { dismiss() }
        }
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(benefits, id: \.self) { b in
                HStack(alignment: .top, spacing: 8) {
                    Text("✓").font(.risoHead(14, .bold)).foregroundStyle(Color.risoGreen)
                    Text(b).font(.risoBody(14, .regular)).foregroundStyle(Color.risoInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var plans: some View {
        if let packages {
            if packages.isEmpty {
                Text("Plans are unavailable right now. Please try again later.")
                    .font(.risoBody(13, .regular))
                    .foregroundStyle(Color.risoMuted)
            } else {
                VStack(spacing: 10) {
                    ForEach(packages, id: \.identifier) { pkg in
                        RisoButton(
                            title: busyProductId == pkg.storeProduct.productIdentifier
                                ? "Please wait…"
                                : "\(pkg.storeProduct.localizedTitle) · \(pkg.storeProduct.localizedPriceString)",
                            kind: .primary,
                            fullWidth: true,
                            large: true
                        ) {
                            buy(pkg)
                        }
                        .disabled(busyProductId != nil)
                    }
                }
            }
        } else {
            ProgressView().tint(Color.risoInk).frame(maxWidth: .infinity)
        }
    }

    private var restoreButton: some View {
        SwiftUI.Button {
            restore()
        } label: {
            Text(isRestoring ? "Restoring…" : "Restore Purchases")
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity)
        }
        .disabled(isRestoring || busyProductId != nil)
    }

    private var legal: some View {
        VStack(spacing: 6) {
            Text("Subscriptions renew automatically until cancelled.")
                .font(.risoBody(11, .regular))
                .foregroundStyle(Color.risoMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("Terms", destination: Self.termsURL)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(.risoBody(11, .semibold))
            .tint(Color.risoRed)
        }
        .frame(maxWidth: .infinity)
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.risoRed)
            Text(text).font(.risoBody(13, .semibold)).foregroundStyle(Color.risoInk)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(fill: .risoPaper)
    }

    // MARK: - Actions

    private func loadOfferings() async {
        guard Purchases.isConfigured else { packages = []; return }
        do {
            let offerings = try await Purchases.shared.offerings()
            packages = offerings.current?.availablePackages ?? []
        } catch {
            packages = []
            errorMessage = "Couldn’t load plans. Please try again."
        }
    }

    private func buy(_ pkg: Package) {
        // Purchasing requires a real account — send guests through upgrade first.
        if authService.isAnonymous {
            showUpgrade = true
            return
        }
        guard busyProductId == nil, Purchases.isConfigured else { return }
        errorMessage = nil
        busyProductId = pkg.storeProduct.productIdentifier
        _Concurrency.Task {
            defer { busyProductId = nil }
            do {
                let result = try await Purchases.shared.purchase(package: pkg)
                if !result.userCancelled {
                    dismiss() // isPro flips via the delegate / entitlements listener
                }
            } catch {
                errorMessage = "That didn’t go through. Please try again."
            }
        }
    }

    private func restore() {
        guard !isRestoring, Purchases.isConfigured else { return }
        errorMessage = nil
        isRestoring = true
        _Concurrency.Task {
            defer { isRestoring = false }
            do {
                _ = try await Purchases.shared.restorePurchases()
                if entitlementService.isPro { dismiss() }
            } catch {
                errorMessage = "Couldn’t restore purchases. Please try again."
            }
        }
    }
}
