/**
 * Emulator-backed test for the `revenueCatWebhook` HTTPS endpoint
 * (functions/src/revenueCatWebhook.ts) — the ONLY writer of the
 * server-authoritative `entitlements/{uid}` collection.
 *
 * Like `subscribe.test.ts`, this hits the endpoint over real HTTP against the
 * FUNCTIONS emulator (it's an `onRequest` handler), then reads back Firestore
 * with the Admin SDK to assert what the function wrote. Requires
 * `firebase emulators:exec --only functions,firestore` with the built
 * `functions/lib/index.js` (so `npm run build` must have run first).
 *
 * The webhook auth secret is injected via `REVENUECAT_WEBHOOK_AUTH` in the
 * environment (the handler falls back to `process.env` in the emulator). The CI
 * step and local run set it; this test reads the same value so the valid-auth
 * path matches.
 */
import { describe, it, expect } from "vitest";
import "../src/index";
import { getFirestore } from "firebase-admin/firestore";

const db = getFirestore();

const PROJECT_ID = process.env.GCLOUD_PROJECT ?? "demo-oybc-functions-test";
const FUNCTIONS_HOST = process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST ?? "127.0.0.1:5001";
const WEBHOOK_URL = `http://${FUNCTIONS_HOST}/${PROJECT_ID}/us-central1/revenueCatWebhook`;
const AUTH = process.env.REVENUECAT_WEBHOOK_AUTH ?? "test-rc-webhook-secret";

let counter = 0;
function freshUid(): string {
  counter += 1;
  return `rc-test-uid-${Date.now()}-${counter}`;
}

interface EventOverrides {
  [key: string]: unknown;
}

function buildEvent(uid: string, overrides: EventOverrides = {}): Record<string, unknown> {
  return {
    id: `evt-${uid}-${Math.floor(Math.random() * 1e9)}`,
    type: "INITIAL_PURCHASE",
    app_user_id: uid,
    product_id: "com.oybc.pro.monthly",
    entitlement_ids: ["oybc_pro"],
    expiration_at_ms: Date.now() + 30 * 24 * 60 * 60 * 1000,
    event_timestamp_ms: Date.now(),
    store: "APP_STORE",
    environment: "SANDBOX",
    ...overrides,
  };
}

async function postWebhook(
  event: Record<string, unknown> | null,
  opts: { auth?: string | null; method?: string } = {}
) {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  const auth = opts.auth === undefined ? AUTH : opts.auth;
  if (auth !== null) headers["Authorization"] = auth;
  const res = await fetch(WEBHOOK_URL, {
    method: opts.method ?? "POST",
    headers,
    body: event === null ? "{}" : JSON.stringify({ event }),
  });
  let json: Record<string, unknown> = {};
  try {
    json = (await res.json()) as Record<string, unknown>;
  } catch {
    /* some error paths may not return JSON */
  }
  return { status: res.status, json };
}

function entitlement(uid: string) {
  return db.doc(`entitlements/${uid}`).get();
}

describe("revenueCatWebhook", () => {
  it("valid INITIAL_PURCHASE → 200 and writes pro entitlement", async () => {
    const uid = freshUid();
    const { status, json } = await postWebhook(buildEvent(uid));
    expect(status).toBe(200);
    expect(json).toEqual({ ok: true });

    const doc = await entitlement(uid);
    expect(doc.exists).toBe(true);
    const data = doc.data()!;
    expect(data.tier).toBe("pro");
    expect(data.isPro).toBe(true);
    expect(data.product).toBe("monthly");
    expect(typeof data.expiresAt).toBe("string");
    expect(data.source).toBe("revenuecat-webhook");
  });

  it("rejects a wrong Authorization header with 401 and writes nothing", async () => {
    const uid = freshUid();
    const { status } = await postWebhook(buildEvent(uid), { auth: "wrong-secret" });
    expect(status).toBe(401);
    expect((await entitlement(uid)).exists).toBe(false);
  });

  it("rejects a missing Authorization header with 401", async () => {
    const uid = freshUid();
    const { status } = await postWebhook(buildEvent(uid), { auth: null });
    expect(status).toBe(401);
    expect((await entitlement(uid)).exists).toBe(false);
  });

  it("rejects a non-POST with 405", async () => {
    const { status } = await postWebhook(buildEvent(freshUid()), { method: "GET" });
    expect(status).toBe(405);
  });

  it("400s a body with no event", async () => {
    const { status } = await postWebhook(null);
    expect(status).toBe(400);
  });

  it("NON_RENEWING_PURCHASE → lifetime pro with null expiry", async () => {
    const uid = freshUid();
    await postWebhook(
      buildEvent(uid, {
        type: "NON_RENEWING_PURCHASE",
        product_id: "com.oybc.pro.lifetime",
        expiration_at_ms: null,
      })
    );
    const data = (await entitlement(uid)).data()!;
    expect(data.tier).toBe("pro");
    expect(data.product).toBe("lifetime");
    expect(data.expiresAt).toBeNull();
  });

  it("EXPIRATION → free", async () => {
    const uid = freshUid();
    await postWebhook(buildEvent(uid)); // becomes pro
    await postWebhook(
      buildEvent(uid, {
        type: "EXPIRATION",
        event_timestamp_ms: Date.now() + 1000, // later than the purchase
      })
    );
    const data = (await entitlement(uid)).data()!;
    expect(data.tier).toBe("free");
    expect(data.isPro).toBe(false);
  });

  it("is idempotent on a redelivered event id", async () => {
    const uid = freshUid();
    const event = buildEvent(uid);
    await postWebhook(event);
    const first = (await entitlement(uid)).data()!;
    // Redeliver the SAME event id but with a later timestamp — must be a no-op.
    await postWebhook({ ...event, event_timestamp_ms: Date.now() + 5000 });
    const second = (await entitlement(uid)).data()!;
    expect(second.eventTimestampMs).toBe(first.eventTimestampMs);
  });

  it("does not regress on a stale (out-of-order) event", async () => {
    const uid = freshUid();
    const t0 = Date.now();
    await postWebhook(buildEvent(uid, { type: "EXPIRATION", event_timestamp_ms: t0 + 10_000 }));
    expect((await entitlement(uid)).data()!.tier).toBe("free");
    // A RENEWAL that actually happened BEFORE the expiration arrives late.
    await postWebhook(
      buildEvent(uid, { id: `stale-${uid}`, type: "RENEWAL", event_timestamp_ms: t0 })
    );
    expect((await entitlement(uid)).data()!.tier).toBe("free"); // stale write ignored
  });

  it("ignores an event for a different entitlement", async () => {
    const uid = freshUid();
    const { status, json } = await postWebhook(buildEvent(uid, { entitlement_ids: ["some_other"] }));
    expect(status).toBe(200);
    expect(json.ignored).toBe("not_pro_or_unknown_type");
    expect((await entitlement(uid)).exists).toBe(false);
  });

  it("acknowledges a TRANSFER without writing", async () => {
    const uid = freshUid();
    const { status, json } = await postWebhook(buildEvent(uid, { type: "TRANSFER" }));
    expect(status).toBe(200);
    expect(json.ignored).toBe("transfer");
    expect((await entitlement(uid)).exists).toBe(false);
  });
});
