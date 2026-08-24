/**
 * Monetization entitlement — the "is this user Pro?" record.
 *
 * **This does NOT ride in the synced `users` doc / `SYNC_COLLECTIONS`.** Those are
 * client-owned last-write-wins state that a modified client can freely overwrite —
 * fine for feature toggles, fatal for a paid flag. Instead the entitlement lives in
 * a **server-authoritative** top-level Firestore collection `entitlements/{uid}`
 * that the client can READ but never WRITE (`firestore.rules`: `allow write: if
 * false`); the only writer is the RevenueCat webhook Cloud Function via the Admin
 * SDK. See docs/MONETIZATION.md.
 *
 * This type is the shape the client decodes from that doc. It is mirrored in Swift
 * by `apps/ios/OYBC/Database/Models/Entitlement.swift` (tolerant `init(from:)`) —
 * keep the two in lock-step, exactly like `UserPreferences`.
 *
 * The client `isPro`/active check derived from this is **UX only, never a security
 * boundary** — anything abuse-sensitive must re-check server-side.
 */

/** Coarse tier. Everything gated reads off this (plus the active/grace check). */
export type EntitlementTier = 'free' | 'pro';

/** Which Pro SKU granted access. `lifetime` is a one-time non-consumable (no expiry). */
export type ProProduct = 'monthly' | 'yearly' | 'lifetime';

/** Originating store, for support/debugging. */
export type EntitlementStore = 'app_store' | 'play_store' | 'stripe' | 'promotional';

export interface Entitlement {
  tier: EntitlementTier;
  /**
   * Denormalized snapshot of `tier === 'pro'` at write time. Convenience only —
   * for gating, prefer the pure `isEntitlementActive()` (constants/proGating),
   * which also applies the expiry + grace window. Never trusted as a security
   * boundary on the client.
   */
  isPro: boolean;
  /** Product that granted Pro; absent when free. */
  product?: ProProduct;
  /**
   * ISO8601 expiry for auto-renewing / expiring products; `null` for `lifetime`
   * (non-expiring); absent when free. The grace window is applied at read time,
   * not baked in here.
   */
  expiresAt?: string | null;
  /** Whether an auto-renewing subscription is set to renew. Absent for lifetime/free. */
  willRenew?: boolean;
  /** Originating store. */
  store?: EntitlementStore;
  /** ISO8601 of the last server write (webhook event time). */
  updatedAt: string;
  /** Provenance marker. `default` = no server doc yet (free fallback). */
  source: 'revenuecat-webhook' | 'default';
}

/**
 * Default entitlement for a user with no `entitlements/{uid}` doc yet, or a
 * missing / malformed record. Free tier, no Pro.
 */
export const DEFAULT_ENTITLEMENT: Entitlement = {
  tier: 'free',
  isPro: false,
  updatedAt: '',
  source: 'default',
};

const PRO_PRODUCTS: readonly ProProduct[] = ['monthly', 'yearly', 'lifetime'];
const ENTITLEMENT_STORES: readonly EntitlementStore[] = [
  'app_store',
  'play_store',
  'stripe',
  'promotional',
];

/**
 * Merge a partial (possibly untrusted) entitlement object with defaults, returning
 * a complete `Entitlement`. Used when decoding the `entitlements/{uid}` doc, which
 * may be absent, partial, or (in the pathological case) malformed.
 *
 * Every field is validated against its allowed value set before being accepted; any
 * field that is missing, the wrong type, or out of range falls back to the default.
 * `isPro` is always recomputed from `tier` (never trusted from the payload) so the
 * two can't disagree. This mirrors `mergeUserPreferences` and the Swift
 * `Entitlement.init(from:)` decoder, so a bad remote payload can't poison local
 * state.
 */
export function mergeEntitlement(
  partial: Partial<Entitlement> | null | undefined
): Entitlement {
  if (!partial) return { ...DEFAULT_ENTITLEMENT };

  const tier: EntitlementTier =
    partial.tier === 'pro' || partial.tier === 'free'
      ? partial.tier
      : DEFAULT_ENTITLEMENT.tier;

  // Free tier carries no product/expiry/renewal metadata.
  if (tier === 'free') {
    return {
      tier: 'free',
      isPro: false,
      updatedAt: typeof partial.updatedAt === 'string' ? partial.updatedAt : '',
      source: partial.source === 'revenuecat-webhook' ? 'revenuecat-webhook' : 'default',
    };
  }

  const product: ProProduct | undefined =
    typeof partial.product === 'string' &&
    PRO_PRODUCTS.includes(partial.product as ProProduct)
      ? (partial.product as ProProduct)
      : undefined;

  // `lifetime` never expires; only subscription products carry an expiry.
  const expiresAt: string | null | undefined =
    product === 'lifetime'
      ? null
      : partial.expiresAt === null
        ? null
        : typeof partial.expiresAt === 'string'
          ? partial.expiresAt
          : undefined;

  const willRenew: boolean | undefined =
    typeof partial.willRenew === 'boolean' ? partial.willRenew : undefined;

  const store: EntitlementStore | undefined =
    typeof partial.store === 'string' &&
    ENTITLEMENT_STORES.includes(partial.store as EntitlementStore)
      ? (partial.store as EntitlementStore)
      : undefined;

  return {
    tier: 'pro',
    isPro: true,
    product,
    expiresAt,
    willRenew,
    store,
    updatedAt: typeof partial.updatedAt === 'string' ? partial.updatedAt : '',
    source: partial.source === 'revenuecat-webhook' ? 'revenuecat-webhook' : 'default',
  };
}
