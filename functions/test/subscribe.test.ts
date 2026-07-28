/**
 * Emulator-backed test for the `subscribe` HTTPS endpoint (the Coming Soon
 * page's email-capture function, see `functions/src/index.ts`).
 *
 * Unlike `purge.test.ts`, this hits the endpoint over real HTTP against the
 * FUNCTIONS emulator (not a direct function call) — `subscribe` is an
 * `onRequest` handler, so exercising it through the emulator's HTTP surface
 * is the only way to cover its actual request/response contract (status
 * codes, JSON shape) rather than just its inner logic. Requires
 * `firebase emulators:exec --only functions,firestore` (see
 * `functions/package.json`'s `test` script), which loads the BUILT
 * `functions/lib/index.js` — so `npm run build` must have already run.
 *
 * `../src/index` is still imported here (for its `initializeApp()`
 * side-effect only) so this file's own Admin SDK calls, used to verify what
 * the emulator's copy of the function actually wrote to Firestore, share one
 * default app rather than double-initializing.
 */
import { describe, it, expect } from "vitest";
import "../src/index";
import { getFirestore } from "firebase-admin/firestore";
import { createHash } from "crypto";

const db = getFirestore();

const PROJECT_ID = process.env.GCLOUD_PROJECT ?? "demo-oybc-functions-test";
const FUNCTIONS_HOST =
  process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST ?? "127.0.0.1:5001";
const SUBSCRIBE_URL = `http://${FUNCTIONS_HOST}/${PROJECT_ID}/us-central1/subscribe`;

/** Mirrors `subscribe`'s own doc-id derivation: sha256 of the lowercased email. */
function emailKey(email: string): string {
  return createHash("sha256").update(email.toLowerCase()).digest("hex");
}

async function postSubscribe(body: Record<string, unknown>) {
  const res = await fetch(SUBSCRIBE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = (await res.json()) as { ok: boolean; error?: string };
  return { status: res.status, json };
}

describe("subscribe", () => {
  it("valid email → 2xx and writes signups/{sha256(email)}", async () => {
    const email = `happy-path-${Date.now()}@example.com`;

    const { status, json } = await postSubscribe({
      email,
      source: "vitest-happy-path",
    });

    expect(status).toBe(200);
    expect(json).toEqual({ ok: true });

    const doc = await db.doc(`signups/${emailKey(email)}`).get();
    expect(doc.exists).toBe(true);
    const data = doc.data();
    expect(data?.email).toBe(email.toLowerCase());
    expect(data?.source).toBe("vitest-happy-path");
  });

  it("honeypot filled → pretends success but writes nothing", async () => {
    const email = `honeypot-${Date.now()}@example.com`;

    const { status, json } = await postSubscribe({
      email,
      source: "vitest-honeypot",
      hp: "i-am-a-bot",
    });

    // Source's honeypot branch always returns 200/{ok:true} — bots must not
    // be able to distinguish "accepted" from "silently dropped".
    expect(status).toBe(200);
    expect(json).toEqual({ ok: true });

    const doc = await db.doc(`signups/${emailKey(email)}`).get();
    expect(doc.exists).toBe(false);
  });

  it("malformed email → 400 and writes nothing", async () => {
    const email = "not-an-email";

    const { status, json } = await postSubscribe({
      email,
      source: "vitest-malformed",
    });

    expect(status).toBe(400);
    expect(json).toEqual({ ok: false, error: "invalid_email" });

    const doc = await db.doc(`signups/${emailKey(email)}`).get();
    expect(doc.exists).toBe(false);
  });

  it("non-POST method → 405", async () => {
    const res = await fetch(SUBSCRIBE_URL, { method: "GET" });
    const json = (await res.json()) as { ok: boolean; error?: string };

    expect(res.status).toBe(405);
    expect(json).toEqual({ ok: false, error: "method_not_allowed" });
  });

  it("re-submit preserves the original createdAt (transaction contract)", async () => {
    // The confirmation-email change rewrote the write as a read-check-write
    // transaction: only a genuinely-new signup stamps createdAt (and triggers
    // the one-time email); a re-submit merges email/source but must NOT touch
    // createdAt or re-send. This pins the createdAt half of that contract —
    // the send itself isn't observable over HTTP.
    const email = `resubmit-${Date.now()}@example.com`;

    await postSubscribe({ email, source: "vitest-first" });
    const first = await db.doc(`signups/${emailKey(email)}`).get();
    const firstCreatedAt = first.data()?.createdAt;
    expect(firstCreatedAt).toBeTruthy();

    const { status, json } = await postSubscribe({ email, source: "vitest-again" });
    expect(status).toBe(200);
    expect(json).toEqual({ ok: true });

    const second = await db.doc(`signups/${emailKey(email)}`).get();
    expect(second.data()?.source).toBe("vitest-again");
    expect(second.data()?.createdAt).toEqual(firstCreatedAt);
  });

  it("signup still succeeds when the Resend send fails (best-effort mail)", async () => {
    // The emulator has no RESEND_API_KEY secret, so sendConfirmationEmail
    // throws inside the function on every new signup in this suite. This test
    // makes that implicit fact an explicit pin: a mail failure must never fail
    // the request or drop the address (the send is wrapped in its own
    // try/catch). If someone ever moves the send inside the write path or lets
    // its error propagate, this is the test that goes red.
    const email = `mail-failure-${Date.now()}@example.com`;

    const { status, json } = await postSubscribe({ email, source: "vitest-mail-failure" });

    expect(status).toBe(200);
    expect(json).toEqual({ ok: true });

    const doc = await db.doc(`signups/${emailKey(email)}`).get();
    expect(doc.exists).toBe(true);
    expect(doc.data()?.email).toBe(email.toLowerCase());
  });
});
