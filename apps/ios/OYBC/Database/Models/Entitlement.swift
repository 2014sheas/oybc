import Foundation

/// Monetization entitlement — the "is this user Pro?" record.
///
/// **Not synced through GRDB / `SYNC_COLLECTIONS`.** Those are client-owned
/// last-write-wins state a modified client can overwrite — fine for feature
/// toggles, fatal for a paid flag. The entitlement lives in a server-authoritative
/// Firestore collection `entitlements/{uid}` the client can READ but never WRITE
/// (rules: `allow write: if false`); the only writer is the RevenueCat webhook
/// Cloud Function via the Admin SDK. See docs/MONETIZATION.md.
///
/// Mirrors the TypeScript `Entitlement` in
/// `packages/shared/src/types/entitlement.ts` (`mergeEntitlement`) — keep the two
/// in lock-step, exactly like `UserPreferences`. The client `isPro`/active check
/// derived from this is **UX only, never a security boundary**.
enum EntitlementTier: String, Codable, Equatable {
    case free
    case pro
}

/// Which Pro SKU granted access. `lifetime` is a one-time non-consumable (no expiry).
enum ProProduct: String, Codable, Equatable {
    case monthly
    case yearly
    case lifetime
}

enum EntitlementStore: String, Codable, Equatable {
    case appStore = "app_store"
    case playStore = "play_store"
    case stripe
    case promotional
}

enum EntitlementSource: String, Codable, Equatable {
    case revenueCatWebhook = "revenuecat-webhook"
    /// No server doc yet (free fallback). Spelled with a suffix because `default`
    /// is a Swift keyword.
    case defaultSource = "default"
}

struct Entitlement: Codable, Equatable {
    var tier: EntitlementTier
    /// Denormalized snapshot of `tier == .pro` at write time. Convenience only —
    /// for gating prefer `ProGating.isEntitlementActive`, which also applies the
    /// expiry + grace window. Never a security boundary on the client.
    var isPro: Bool
    var product: ProProduct?
    /// ISO8601 expiry for subscriptions; `nil` for lifetime / free.
    var expiresAt: String?
    var willRenew: Bool?
    var store: EntitlementStore?
    var updatedAt: String
    var source: EntitlementSource

    /// Free default for a user with no `entitlements/{uid}` doc, or a malformed one.
    static let free = Entitlement(
        tier: .free,
        isPro: false,
        product: nil,
        expiresAt: nil,
        willRenew: nil,
        store: nil,
        updatedAt: "",
        source: .defaultSource
    )

    init(
        tier: EntitlementTier,
        isPro: Bool,
        product: ProProduct?,
        expiresAt: String?,
        willRenew: Bool?,
        store: EntitlementStore?,
        updatedAt: String,
        source: EntitlementSource
    ) {
        self.tier = tier
        self.isPro = isPro
        self.product = product
        self.expiresAt = expiresAt
        self.willRenew = willRenew
        self.store = store
        self.updatedAt = updatedAt
        self.source = source
    }

    /// Fills missing fields from `.free`. Mirrors the TS `mergeEntitlement` entry.
    static func merge(_ partial: Entitlement?) -> Entitlement {
        partial ?? .free
    }

    // MARK: - Codable (tolerant, mirrors TS `mergeEntitlement`)

    /// Tolerant decode: unknown tier → free; `isPro` always recomputed from tier
    /// (never trusts a spoofed value); free tier strips product/expiry/renewal
    /// metadata; `lifetime` forces `expiresAt = nil`. So a bad remote payload can't
    /// poison local state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTier = (try? c.decode(EntitlementTier.self, forKey: .tier)) ?? .free
        let decodedSource = (try? c.decode(EntitlementSource.self, forKey: .source)) ?? .defaultSource
        let decodedUpdatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""

        if decodedTier == .free {
            self.tier = .free
            self.isPro = false
            self.product = nil
            self.expiresAt = nil
            self.willRenew = nil
            self.store = nil
            self.updatedAt = decodedUpdatedAt
            self.source = decodedSource
            return
        }

        self.tier = .pro
        self.isPro = true
        let decodedProduct = try? c.decode(ProProduct.self, forKey: .product)
        self.product = decodedProduct
        // Invalid product/store raw values fail `try?` → nil, matching TS drop-to-undefined.
        if decodedProduct == .lifetime {
            self.expiresAt = nil // lifetime never expires
        } else {
            // Both an explicit null and a missing key decode to nil here.
            self.expiresAt = try? c.decode(String.self, forKey: .expiresAt)
        }
        self.willRenew = try? c.decode(Bool.self, forKey: .willRenew)
        self.store = try? c.decode(EntitlementStore.self, forKey: .store)
        self.updatedAt = decodedUpdatedAt
        self.source = decodedSource
    }
}
