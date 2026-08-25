/**
 * RevenueCat webhook — the ONLY writer of the server-authoritative
 * `entitlements/{uid}` collection (docs/MONETIZATION.md). RevenueCat POSTs a
 * subscriber-lifecycle event here; we verify it, derive the Pro state, and write
 * it via the Admin SDK (which bypasses `firestore.rules`, where the collection is
 * `allow write: if false`). Clients only ever READ their own entitlement doc.
 *
 * Mirrors the security posture of `subscribe`/`unsubscribe`:
 *  - `onRequest` public endpoint, method-guarded (POST only).
 *  - Auth via a shared secret (`REVENUECAT_WEBHOOK_AUTH`) sent in the
 *    `Authorization` header and compared in constant time. Fails CLOSED if the
 *    secret is unconfigured (never accept-all).
 *  - Idempotent, monotonic transactional write so RevenueCat's at-least-once /
 *    out-of-order redelivery can't regress a fresh entitlement.
 *
 * `app_user_id` is the Firebase uid (the client sets RevenueCat's appUserID to
 * it). Because purchasing requires a real account (no guest purchases — see the
 * plan), entitlements only ever exist on real uids, so there is no TRANSFER
 * handling: a TRANSFER event is logged and acknowledged without a write.
 */
import { onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { defineSecret } from "firebase-functions/params";
import { getFirestore } from "firebase-admin/firestore";
import { timingSafeEqual } from "crypto";

/**
 * Shared secret RevenueCat sends in the webhook `Authorization` header. Set once
 * with `firebase functions:secrets:set REVENUECAT_WEBHOOK_AUTH` and paste the same
 * value into the RevenueCat dashboard's webhook Authorization field. The emulator
 * suite injects it via `process.env` (see the `|| process.env` fallback below).
 */
export const REVENUECAT_WEBHOOK_AUTH = defineSecret("REVENUECAT_WEBHOOK_AUTH");

/** Must match `PRO_ENTITLEMENT_ID` in packages/shared/src/constants/proGating.ts. */
const PRO_ENTITLEMENT_ID = "pro";

/** Event types that grant/continue Pro access (access persists until expiry). */
const GRANT_TYPES = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "UNCANCELLATION",
  "PRODUCT_CHANGE",
  "NON_RENEWING_PURCHASE", // lifetime
  "CANCELLATION", // auto-renew off, but access continues until expiresAt
  "BILLING_ISSUE", // grace period; client grace check covers the tail
  "SUBSCRIPTION_EXTENDED",
]);

/** Event types that revoke Pro access. */
const REVOKE_TYPES = new Set(["EXPIRATION"]);

/** Minimal shape of the RevenueCat webhook `event` object (fields we read). */
interface RevenueCatEvent {
  id?: string;
  type?: string;
  app_user_id?: string;
  product_id?: string;
  entitlement_id?: string | null;
  entitlement_ids?: string[] | null;
  expiration_at_ms?: number | null;
  event_timestamp_ms?: number;
  store?: string;
  environment?: string;
}

type ProProduct = "monthly" | "yearly" | "lifetime";
type EntitlementStore = "app_store" | "play_store" | "stripe" | "promotional";

/** The Pro-state fields derived from an event (before bookkeeping is attached). */
interface DerivedEntitlement {
  tier: "free" | "pro";
  isPro: boolean;
  product?: ProProduct;
  expiresAt?: string | null;
  willRenew?: boolean;
  store?: EntitlementStore;
  updatedAt: string;
}

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

function mapStore(store: string | undefined): EntitlementStore | undefined {
  switch ((store ?? "").toUpperCase()) {
    case "APP_STORE":
    case "MAC_APP_STORE":
      return "app_store";
    case "PLAY_STORE":
      return "play_store";
    case "STRIPE":
    case "RC_BILLING":
      return "stripe";
    case "PROMOTIONAL":
      return "promotional";
    default:
      return undefined;
  }
}

/** Best-effort product mapping (display only — gating uses tier + expiresAt). */
function inferProduct(event: RevenueCatEvent): ProProduct | undefined {
  if (event.type === "NON_RENEWING_PURCHASE" || event.expiration_at_ms == null) {
    return "lifetime";
  }
  const pid = (event.product_id ?? "").toLowerCase();
  if (/year|annual|annum/.test(pid)) return "yearly";
  if (/month/.test(pid)) return "monthly";
  return undefined;
}

/**
 * Pure derivation of the entitlement state from a webhook event. Returns `null`
 * when the event doesn't concern the `pro` entitlement or is an unknown/ignored
 * type (the caller acks it without a write). Exported for direct unit testing.
 */
export function deriveEntitlement(event: RevenueCatEvent): DerivedEntitlement | null {
  const type = event.type ?? "";

  // Scope to the `pro` entitlement when the event names entitlements at all.
  const ents = event.entitlement_ids ?? (event.entitlement_id ? [event.entitlement_id] : null);
  if (ents && !ents.includes(PRO_ENTITLEMENT_ID)) return null;

  const tsMs = typeof event.event_timestamp_ms === "number" ? event.event_timestamp_ms : Date.now();
  const updatedAt = new Date(tsMs).toISOString();

  if (REVOKE_TYPES.has(type)) {
    return { tier: "free", isPro: false, updatedAt };
  }
  if (!GRANT_TYPES.has(type)) return null;

  const product = inferProduct(event);
  const expiresAt =
    product === "lifetime"
      ? null
      : typeof event.expiration_at_ms === "number"
        ? new Date(event.expiration_at_ms).toISOString()
        : null;
  const willRenew = type !== "CANCELLATION" && product !== "lifetime";

  return {
    tier: "pro",
    isPro: true,
    product,
    expiresAt,
    willRenew,
    store: mapStore(event.store),
    updatedAt,
  };
}

export const revenueCatWebhook = onRequest(
  { secrets: [REVENUECAT_WEBHOOK_AUTH] },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ ok: false, error: "method_not_allowed" });
      return;
    }

    // Fail CLOSED if the secret is unconfigured — never accept-all. (In the
    // emulator the secret comes from process.env; in prod from Secret Manager.)
    const expected = REVENUECAT_WEBHOOK_AUTH.value() || process.env.REVENUECAT_WEBHOOK_AUTH || "";
    if (!expected) {
      logger.error("revenueCatWebhook: REVENUECAT_WEBHOOK_AUTH is not configured");
      res.status(500).json({ ok: false, error: "not_configured" });
      return;
    }
    const provided = req.get("authorization") ?? "";
    if (!safeEqual(provided, expected)) {
      res.status(401).json({ ok: false, error: "unauthorized" });
      return;
    }

    const event = (req.body?.event ?? null) as RevenueCatEvent | null;
    if (!event || typeof event !== "object") {
      res.status(400).json({ ok: false, error: "missing_event" });
      return;
    }

    // TRANSFER is not expected: purchasing requires a real account, so an
    // entitlement never lives on a transferable anonymous uid. Log + ack.
    if (event.type === "TRANSFER") {
      logger.warn("revenueCatWebhook: TRANSFER received (unexpected; guest purchases disabled) — ignoring", {
        id: event.id,
      });
      res.status(200).json({ ok: true, ignored: "transfer" });
      return;
    }

    const uid = typeof event.app_user_id === "string" ? event.app_user_id : "";
    if (!uid) {
      res.status(400).json({ ok: false, error: "missing_app_user_id" });
      return;
    }

    const derived = deriveEntitlement(event);
    if (!derived) {
      res.status(200).json({ ok: true, ignored: "not_pro_or_unknown_type" });
      return;
    }

    try {
      const db = getFirestore();
      const ref = db.collection("entitlements").doc(uid);
      const tsMs = typeof event.event_timestamp_ms === "number" ? event.event_timestamp_ms : 0;

      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (snap.exists) {
          const prev = snap.data() ?? {};
          // Idempotent: a redelivered identical event is a no-op.
          if (event.id && prev.lastEventId === event.id) return;
          // Monotonic: never let a stale/out-of-order event regress a fresher one.
          if (typeof prev.eventTimestampMs === "number" && tsMs < prev.eventTimestampMs) return;
        }

        // Full overwrite (not merge) so downgrading to free can't leave stale
        // product/expiry fields behind. Build without `undefined` values — the
        // Admin SDK rejects them.
        const doc: Record<string, unknown> = {
          tier: derived.tier,
          isPro: derived.isPro,
          updatedAt: derived.updatedAt,
          source: "revenuecat-webhook",
          lastEventId: event.id ?? null,
          eventTimestampMs: tsMs,
          environment: event.environment ?? null,
        };
        if (derived.tier === "pro") {
          if (derived.product !== undefined) doc.product = derived.product;
          doc.expiresAt = derived.expiresAt ?? null;
          if (derived.willRenew !== undefined) doc.willRenew = derived.willRenew;
          if (derived.store !== undefined) doc.store = derived.store;
        }
        tx.set(ref, doc);
      });

      res.status(200).json({ ok: true });
    } catch (err) {
      logger.error("revenueCatWebhook write failed", err);
      res.status(500).json({ ok: false, error: "internal" });
    }
  }
);
