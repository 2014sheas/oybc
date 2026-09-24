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
 *
 * Hardening (2026-09 security audit):
 *  - ENVIRONMENT GATE: events whose `environment` is not in the
 *    `REVENUECAT_ALLOWED_ENVIRONMENTS` param (comma-separated; default
 *    `PRODUCTION,SANDBOX` so the dev project keeps accepting sandbox
 *    purchases) are acknowledged with 200 and write nothing. **The prod
 *    project MUST set `REVENUECAT_ALLOWED_ENVIRONMENTS=PRODUCTION`** (via
 *    `functions/.env.<prod-project-id>`, see functions/README.md) — otherwise a
 *    free sandbox purchase would grant real Pro.
 *  - `app_user_id` must look like a Firebase uid (`/^[A-Za-z0-9]{20,128}$/`);
 *    anything else is acknowledged with 200 (so RevenueCat stops retrying)
 *    and writes nothing. Only the SHAPE of bad input is logged.
 *  - Grants require the `oybc_pro` entitlement id to be present on the event.
 *  - A null expiry only means "lifetime" for NON_RENEWING_PURCHASE (or an
 *    INITIAL_PURCHASE/RENEWAL of a lifetime product id); a CANCELLATION never
 *    infers lifetime. A refund CANCELLATION (`cancel_reason: CUSTOMER_SUPPORT`)
 *    revokes.
 *  - The Authorization compare hashes both sides first (no length leak).
 */
import { onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { defineSecret, defineString } from "firebase-functions/params";
import { getFirestore } from "firebase-admin/firestore";
import { createHash, timingSafeEqual } from "crypto";

/**
 * Shared secret RevenueCat sends in the webhook `Authorization` header. Set once
 * with `firebase functions:secrets:set REVENUECAT_WEBHOOK_AUTH` and paste the same
 * value into the RevenueCat dashboard's webhook Authorization field. The emulator
 * suite injects it via `process.env` (see the `|| process.env` fallback below).
 */
export const REVENUECAT_WEBHOOK_AUTH = defineSecret("REVENUECAT_WEBHOOK_AUTH");

/**
 * Comma-separated RevenueCat `environment` values this deployment accepts
 * (documented values: `SANDBOX`, `PRODUCTION` —
 * https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields).
 * Default keeps the dev project working with sandbox purchases; the PROD project
 * must override it to `PRODUCTION` (see functions/README.md).
 */
export const REVENUECAT_ALLOWED_ENVIRONMENTS = defineString("REVENUECAT_ALLOWED_ENVIRONMENTS", {
  default: "PRODUCTION,SANDBOX",
});

/** A Firebase Auth uid: alphanumeric (28 chars in practice); bounds are defensive. */
const APP_USER_ID_RE = /^[A-Za-z0-9]{20,128}$/;

/**
 * RevenueCat `cancel_reason` values that mean the purchase was REFUNDED, so
 * access ends now rather than at `expiresAt`. Per the RevenueCat webhook docs
 * (https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields,
 * "Cancellation and Expiration Reasons"), `CUSTOMER_SUPPORT` = "Customer received
 * a refund from Apple support, a Play Store subscription was refunded through
 * RevenueCat, …" — it is also how a refunded NON_RENEWING_PURCHASE (our lifetime
 * SKU) is reported. `UNSUBSCRIBE`, `BILLING_ERROR`, `DEVELOPER_INITIATED`,
 * `PRICE_INCREASE` and `UNKNOWN` are NOT refunds: access continues until expiry.
 * RevenueCat documents no separate chargeback reason.
 */
const REFUND_CANCEL_REASONS = new Set(["CUSTOMER_SUPPORT"]);

/** Must match `PRO_ENTITLEMENT_ID` in packages/shared/src/constants/proGating.ts. */
const PRO_ENTITLEMENT_ID = "oybc_pro";

/**
 * Event types that grant/continue Pro access (access persists until expiry).
 * Documented types: https://www.revenuecat.com/docs/integrations/webhooks/event-types-and-fields
 */
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
  cancel_reason?: string | null;
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

/**
 * Constant-time string equality. Both sides are SHA-256-hashed first so the
 * compared buffers are always 32 bytes — no early return on a length mismatch
 * that would leak the secret's length through timing.
 *
 * @param a - Provided value (e.g. the request's Authorization header).
 * @param b - Expected value (the configured secret).
 * @returns Whether the two strings are equal.
 */
export function safeEqual(a: string, b: string): boolean {
  const ad = createHash("sha256").update(a, "utf8").digest();
  const bd = createHash("sha256").update(b, "utf8").digest();
  return timingSafeEqual(ad, bd);
}

/**
 * Whether an event's `environment` is accepted by this deployment.
 *
 * @param environment - The event's `environment` field (may be absent).
 * @param allowList - Comma-separated accepted values (the param's value).
 * @returns `true` when the field is absent (RevenueCat always sends it; an
 *   absent value is not evidence of sandbox) or listed; `false` otherwise.
 */
export function isAllowedEnvironment(environment: unknown, allowList: string): boolean {
  if (environment === undefined || environment === null) return true;
  if (typeof environment !== "string") return false;
  const allowed = allowList
    .split(",")
    .map((e) => e.trim().toUpperCase())
    .filter((e) => e.length > 0);
  return allowed.includes(environment.toUpperCase());
}

/**
 * Whether `app_user_id` has the shape of a Firebase uid.
 *
 * @param uid - The event's `app_user_id`.
 * @returns `true` for 20–128 ASCII alphanumerics.
 */
export function isValidAppUserId(uid: unknown): uid is string {
  return typeof uid === "string" && APP_USER_ID_RE.test(uid);
}

/** Loggable SHAPE of an untrusted value (never the value itself). */
function shapeOf(value: unknown): { type: string; length?: number } {
  if (typeof value === "string") return { type: "string", length: value.length };
  if (Array.isArray(value)) return { type: "array", length: value.length };
  return { type: value === null ? "null" : typeof value };
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

/**
 * Grant-type events for which a null `expiration_at_ms` may still mean
 * "lifetime" — but ONLY when the product id names the lifetime SKU. Every other
 * grant type (notably CANCELLATION) with a null expiry is NOT a grant.
 */
const LIFETIME_BY_PRODUCT_ID_TYPES = new Set(["INITIAL_PURCHASE", "RENEWAL"]);

/** Product-id family match (same best-effort convention as yearly/monthly). */
function isLifetimeProductId(productId: string | undefined): boolean {
  return /lifetime/.test((productId ?? "").toLowerCase());
}

/**
 * Best-effort product mapping (display only — gating uses tier + expiresAt).
 * A null expiry is only read as lifetime for NON_RENEWING_PURCHASE; callers
 * gate the other null-expiry cases before calling this.
 */
function inferProduct(event: RevenueCatEvent): ProProduct | undefined {
  if (event.type === "NON_RENEWING_PURCHASE") return "lifetime";
  const pid = (event.product_id ?? "").toLowerCase();
  if (event.expiration_at_ms == null && isLifetimeProductId(pid)) return "lifetime";
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

  // Revokes may proceed without entitlement ids (an EXPIRATION / refund of a
  // purchase whose entitlement mapping is absent must still remove access).
  const isRefund =
    type === "CANCELLATION" &&
    typeof event.cancel_reason === "string" &&
    REFUND_CANCEL_REASONS.has(event.cancel_reason);
  if (REVOKE_TYPES.has(type) || isRefund) {
    return { tier: "free", isPro: false, updatedAt };
  }
  if (!GRANT_TYPES.has(type)) return null;

  // Grants require the Pro entitlement to be explicitly named.
  if (!ents) {
    logger.warn("revenueCatWebhook: grant-type event without entitlement ids — not granting", { type });
    return null;
  }

  // A null expiry is only a lifetime grant for NON_RENEWING_PURCHASE, or an
  // INITIAL_PURCHASE/RENEWAL of the lifetime SKU. Anything else (e.g. a
  // CANCELLATION with no expiry) must not grant open-ended Pro.
  if (
    event.expiration_at_ms == null &&
    type !== "NON_RENEWING_PURCHASE" &&
    !(LIFETIME_BY_PRODUCT_ID_TYPES.has(type) && isLifetimeProductId(event.product_id))
  ) {
    logger.warn("revenueCatWebhook: null expiry on a non-lifetime grant event — not granting", {
      type,
      productId: shapeOf(event.product_id),
    });
    return null;
  }

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

    // Environment gate: e.g. a SANDBOX (free) purchase must never grant Pro on
    // the prod project. 200 so RevenueCat doesn't retry; nothing written.
    if (!isAllowedEnvironment(event.environment, REVENUECAT_ALLOWED_ENVIRONMENTS.value())) {
      logger.warn("revenueCatWebhook: event environment not allowed here — ignoring", {
        environment: shapeOf(event.environment),
      });
      res.status(200).json({ ok: true, ignored: "environment" });
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

    const rawUid = event.app_user_id;
    if (rawUid === undefined || rawUid === null || rawUid === "") {
      res.status(400).json({ ok: false, error: "missing_app_user_id" });
      return;
    }
    // Anything that isn't a Firebase-uid shape (e.g. a RevenueCat anonymous
    // `$RCAnonymousID:…`, or a path-traversal attempt) is acked (200, so
    // RevenueCat stops retrying) and never used as a document id.
    if (!isValidAppUserId(rawUid)) {
      logger.warn("revenueCatWebhook: app_user_id is not a uid shape — ignoring", {
        appUserId: shapeOf(rawUid),
      });
      res.status(200).json({ ok: true, ignored: "app_user_id" });
      return;
    }
    const uid = rawUid;

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
