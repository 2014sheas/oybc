/**
 * Emulator-backed tests for the `unsubscribe` HTTPS endpoint (the launch-list
 * unsubscribe surface linked from the confirmation email + the RFC 8058
 * `List-Unsubscribe-Post` one-click target). Same HTTP-level pattern as
 * `subscribe.test.ts`: real requests against the Functions emulator, Admin SDK
 * reads to verify what was persisted.
 */
import { describe, it, expect } from "vitest";
import "../src/index";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { createHash } from "crypto";

const db = getFirestore();

const PROJECT_ID = process.env.GCLOUD_PROJECT ?? "demo-oybc-functions-test";
const FUNCTIONS_HOST =
  process.env.FIREBASE_FUNCTIONS_EMULATOR_HOST ?? "127.0.0.1:5001";
const UNSUB_URL = `http://${FUNCTIONS_HOST}/${PROJECT_ID}/us-central1/unsubscribe`;

function emailKey(email: string): string {
  return createHash("sha256").update(email.toLowerCase()).digest("hex");
}

async function seedSignup(email: string): Promise<string> {
  const key = emailKey(email);
  await db.doc(`signups/${key}`).set({
    email: email.toLowerCase(),
    source: "vitest",
    createdAt: FieldValue.serverTimestamp(),
  });
  return key;
}

describe("unsubscribe", () => {
  it("GET with a valid token renders the confirm page (no write)", async () => {
    const key = await seedSignup(`unsub-get-${Date.now()}@example.com`);

    const res = await fetch(`${UNSUB_URL}?u=${key}`);
    const body = await res.text();

    expect(res.status).toBe(200);
    expect(body).toContain("Leave the list?");
    expect(body).toContain(`action="/unsubscribe?u=${key}"`);

    const doc = await db.doc(`signups/${key}`).get();
    expect(doc.data()?.unsubscribed).toBeUndefined();
  });

  it("POST with a valid token marks the signup unsubscribed (doc kept)", async () => {
    const email = `unsub-post-${Date.now()}@example.com`;
    const key = await seedSignup(email);

    const res = await fetch(`${UNSUB_URL}?u=${key}`, { method: "POST" });
    const body = await res.text();

    expect(res.status).toBe(200);
    expect(body).toContain("You're off the list.");

    const doc = await db.doc(`signups/${key}`).get();
    expect(doc.exists).toBe(true);
    expect(doc.data()?.unsubscribed).toBe(true);
    expect(doc.data()?.unsubscribedAt).toBeTruthy();
    expect(doc.data()?.email).toBe(email.toLowerCase());
  });

  it("POST is idempotent — a second unsubscribe stays unsubscribed", async () => {
    const key = await seedSignup(`unsub-idem-${Date.now()}@example.com`);
    await fetch(`${UNSUB_URL}?u=${key}`, { method: "POST" });
    const res = await fetch(`${UNSUB_URL}?u=${key}`, { method: "POST" });
    expect(res.status).toBe(200);
    const doc = await db.doc(`signups/${key}`).get();
    expect(doc.data()?.unsubscribed).toBe(true);
  });

  it("POST with an unknown token shows success but never CREATES a doc", async () => {
    const ghost = emailKey(`never-signed-up-${Date.now()}@example.com`);

    const res = await fetch(`${UNSUB_URL}?u=${ghost}`, { method: "POST" });
    const body = await res.text();

    expect(res.status).toBe(200);
    expect(body).toContain("You're off the list.");

    const doc = await db.doc(`signups/${ghost}`).get();
    expect(doc.exists).toBe(false);
  });

  it("GET with a malformed token renders the bad-link page, not the confirm form", async () => {
    const res = await fetch(`${UNSUB_URL}?u=<script>alert(1)</script>`);
    const body = await res.text();
    expect(res.status).toBe(200);
    expect(body).toContain("That link didn't work.");
    expect(body).not.toContain("<script>alert(1)</script>");
    expect(body).not.toContain("Take me off the list");
  });

  it("non-GET/POST methods → 405", async () => {
    const res = await fetch(UNSUB_URL, { method: "DELETE" });
    expect(res.status).toBe(405);
  });
});
