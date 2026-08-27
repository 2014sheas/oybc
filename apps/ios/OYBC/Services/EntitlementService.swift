import Foundation
import FirebaseFirestore
import RevenueCat

/// EntitlementService — the iOS client entitlement layer (docs/MONETIZATION.md).
///
/// Mirrors the web `useEntitlement` hook: combines two signals into a reactive
/// `isPro`, following the "authority vs. display" split.
///  - **Authority:** a live Firestore listener on `entitlements/{uid}` (written
///    ONLY by the RevenueCat webhook), decoded through the tolerant
///    `Entitlement` decoder and evaluated with the shared grace window via
///    `ProGating.isEntitlementActive`.
///  - **Display fast-path:** RevenueCat's cached `CustomerInfo` (offline-capable),
///    kept live via the `PurchasesDelegate`.
///
/// `isPro` is the OR of the two, so a stale/offline authority read never locks out
/// a paying user. **UX only — never a security boundary** (abuse-sensitive checks
/// re-verify server-side).
///
/// Owned by `AuthService` (like `syncService`), which drives `identify`/`reset`
/// from its auth-state listener. RevenueCat's `appUserID` is the Firebase uid, so
/// purchases resolve to the same entitlement across web + iOS.
@MainActor
final class EntitlementService: NSObject, ObservableObject {
    /// The server-authoritative entitlement doc (or `.free`).
    @Published private(set) var entitlement: Entitlement = .free
    /// Effective Pro status for gating.
    @Published private(set) var isPro: Bool = false

    /// RevenueCat publishable (client) App Store API key — designed to ship in the
    /// binary. Not a secret; the server-authoritative entitlement is the real gate.
    private static let revenueCatAPIKey = "appl_udtdbpwcmuFIgbBemmntuabvSUF"

    private let db = Firestore.firestore()
    private var entitlementListener: ListenerRegistration?
    private var rcActive = false
    private var docEntitlement: Entitlement = .free

    /// Configure RevenueCat once at launch (anonymous until `identify`). Call from
    /// `OYBCApp.init()` AFTER `FirebaseApp.configure()`. No-op if already configured.
    static func configureRevenueCat() {
        guard !Purchases.isConfigured else { return }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: revenueCatAPIKey)
    }

    override init() {
        super.init()
        // Receive live CustomerInfo updates (renewals/purchases/expirations).
        // Guarded so tests / -bypassAuth (RevenueCat never configured) are no-ops.
        if Purchases.isConfigured {
            Purchases.shared.delegate = self
        }
    }

    /// Point RevenueCat at the Firebase uid and attach the authority listener.
    /// Called by `AuthService` on sign-in and after a guest→account upgrade (uid
    /// preserved → the `logIn` is a cheap no-op). The collision account-switch
    /// fires the auth-state listener with a new user, which calls this with the
    /// new uid.
    func identify(userId: String) {
        attachListener(userId: userId)
        guard Purchases.isConfigured else { return }
        _Concurrency.Task { [weak self] in
            do {
                let (info, _) = try await Purchases.shared.logIn(userId)
                await self?.apply(customerInfo: info)
            } catch {
                dlog("⚠️ EntitlementService.identify logIn failed: \(error)")
            }
        }
    }

    /// Detach + reset on sign-out (RevenueCat reverts to an anonymous id).
    func reset() {
        detachListener()
        docEntitlement = .free
        rcActive = false
        entitlement = .free
        isPro = false
        guard Purchases.isConfigured else { return }
        _Concurrency.Task { _ = try? await Purchases.shared.logOut() }
    }

    // MARK: - Authority (Firestore)

    private func attachListener(userId: String) {
        detachListener()
        entitlementListener = db.collection("entitlements").document(userId)
            .addSnapshotListener { [weak self] snapshot, _ in
                let decoded: Entitlement = {
                    guard let snapshot, snapshot.exists else { return .free }
                    return (try? snapshot.data(as: Entitlement.self)) ?? .free
                }()
                _Concurrency.Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.docEntitlement = decoded
                    self.recompute()
                }
            }
    }

    private func detachListener() {
        entitlementListener?.remove()
        entitlementListener = nil
    }

    // MARK: - Display (RevenueCat)

    private func apply(customerInfo: CustomerInfo) {
        rcActive = customerInfo.entitlements.active[ProGating.entitlementID] != nil
        recompute()
    }

    private func recompute() {
        entitlement = docEntitlement
        isPro = rcActive || ProGating.isEntitlementActive(docEntitlement, now: Date())
    }
}

extension EntitlementService: PurchasesDelegate {
    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        _Concurrency.Task { @MainActor [weak self] in
            self?.apply(customerInfo: customerInfo)
        }
    }
}
