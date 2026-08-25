/**
 * OYBC Cloud Functions — server-side account-data deletion.
 *
 * Firebase Auth and Firestore are independent: deleting the Auth user does NOT
 * remove their Firestore data, and the security rules forbid the client from
 * deleting the parent `users/{uid}` doc (`allow delete: if false`). The only way
 * to fully purge a user's data is server-side with the Admin SDK, which bypasses
 * security rules. That's what these functions do.
 *
 * Two entry points, by design:
 *  - `onUserDeleted` (Auth `onDelete` trigger) is the PRIMARY purge path. The
 *    iOS client deletes the Auth user FIRST (the only step that can fail for
 *    auth reasons), and this trigger then recursively purges their Firestore
 *    data server-side. Delete-first avoids any window where data is purged but
 *    the account survives (which a pre-delete purge would risk if the delete
 *    then failed). `failurePolicy: true` enables automatic retries so a
 *    transient failure still converges; `recursiveDelete` is idempotent.
 *  - `deleteUserData` (HTTPS callable) is kept as shared, reusable infra for a
 *    future web client (which may prefer a confirmable synchronous purge before
 *    sign-out). Not called by iOS. Idempotent with the trigger.
 */

import { onCall, onRequest, HttpsError } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { defineSecret } from "firebase-functions/params";
import * as functionsV1 from "firebase-functions/v1";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { createHash } from "crypto";
import { Resend } from "resend";
import { confirmationEmailHtml, confirmationEmailText } from "./confirmEmail";
import { buildSignupNotification } from "./signupNotify";

export { validateWin } from "./validateWin";
export { revenueCatWebhook } from "./revenueCatWebhook";

initializeApp();

/**
 * Recursively deletes a user's parent doc and every subcollection beneath it
 * (`users/{uid}` + boards/tasks/boardTasks/compoundChildren/... ). Idempotent:
 * deleting already-absent docs is a no-op.
 *
 * Exported (in addition to being used by the two entry points below) so the
 * emulator-backed test suite (`functions/test/purge.test.ts`) can invoke the
 * purge directly against the Firestore emulator without going through the
 * Functions emulator's auth/trigger plumbing.
 */
export async function purgeUserData(uid: string): Promise<void> {
  const db = getFirestore();
  const userDoc = db.collection("users").doc(uid);
  await db.recursiveDelete(userDoc);
  logger.info(`Purged Firestore data for user ${uid}`);
}

/**
 * HTTPS-callable invoked by the authenticated client immediately before it
 * deletes its own Auth user. The uid is taken from the verified auth context —
 * never from a client-supplied argument — so a caller can only delete its own
 * data.
 */
export const deleteUserData = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Must be signed in to delete account data.");
  }

  try {
    await purgeUserData(uid);
    return { ok: true };
  } catch (err) {
    logger.error(`deleteUserData failed for ${uid}`, err);
    throw new HttpsError("internal", "Failed to delete account data. Please try again.");
  }
});

/* ============================================================
   Launch-email capture for the oybc.com "Coming Soon" placeholder.
   ============================================================ */

/** Same courtesy regex the client uses; re-validated here authoritatively. */
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Resend API key, stored as a Cloud Functions secret (never in source/env
 * files). Set it once with `firebase functions:secrets:set RESEND_API_KEY`
 * before deploying. The `subscribe` function below binds it via `secrets:`.
 */
const RESEND_API_KEY = defineSecret("RESEND_API_KEY");

/**
 * From-address for the confirmation email; must be a Resend-verified domain in
 * production. Overridable via the `CONFIRM_FROM` env var so local testing can use
 * Resend's shared `onboarding@resend.dev` (which needs no domain verification)
 * without a code edit.
 */
const CONFIRM_FROM = process.env.CONFIRM_FROM || "OYBC <hello@oybc.com>";
const SEASON = "Fall 2026";

/**
 * Public origin used in email links (unsubscribe). Overridable via env so the
 * emulator suite can point links at itself; production default is the apex.
 */
const PUBLIC_ORIGIN = process.env.PUBLIC_ORIGIN || "https://oybc.com";

/**
 * Shared minimal page shell for the unsubscribe confirm/done pages — inline
 * Riso-token styling (byte-values from apps/coming-soon), no external assets.
 */
function unsubscribePage(inner: string): string {
  return (
    `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<meta name="robots" content="noindex,nofollow"><title>OYBC — Unsubscribe</title></head>` +
    `<body style="margin:0;background:#f1e9d9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#18120b">` +
    `<div style="max-width:420px;margin:12vh auto 0;padding:0 16px;text-align:center">` +
    `<div style="font-weight:800;letter-spacing:2px;font-size:14px;margin-bottom:18px">OYBC` +
    `<span style="color:#7e7460;font-size:10px;letter-spacing:3px"> · ON YOUR BINGO CARD</span></div>` +
    `<div style="background:#fbf6ea;border:3px solid #18120b;border-radius:18px;padding:28px 22px">${inner}</div>` +
    `</div></body></html>`
  );
}

/**
 * Unsubscribe endpoint, served on the apex as `/unsubscribe?u=<token>` via a
 * Firebase Hosting rewrite (registered BEFORE the catch-all so it wins).
 * The token is the signup doc id (sha256 of the lowercased email) — the same
 * derivation `subscribe` writes, so no extra state is needed.
 *
 * - GET renders a confirm page with a POST button. The interstitial exists
 *   because mail security scanners prefetch GETs in email bodies — a
 *   GET-that-unsubscribes would silently remove real subscribers.
 * - POST performs the unsubscribe: marks the doc `unsubscribed: true` +
 *   `unsubscribedAt` (kept, never deleted — the launch send filters on it).
 *   Also accepts RFC 8058 one-click POSTs (the `List-Unsubscribe-Post`
 *   header target), which mailbox providers call directly.
 * - Unknown/missing tokens still render the success page — an unsubscribe
 *   surface must not act as a membership oracle. Idempotent throughout.
 */
export const unsubscribe = onRequest(async (req, res) => {
  const token = typeof req.query.u === "string" ? req.query.u : "";
  const validToken = /^[a-f0-9]{64}$/.test(token);

  if (req.method === "GET") {
    if (!validToken) {
      res.status(200).send(unsubscribePage(
        `<h1 style="font-size:22px;margin:0 0 10px">That link didn't work.</h1>` +
        `<p style="font-size:14px;line-height:1.5;color:#7e7460;margin:0">` +
        `Use the unsubscribe link from your email, or write to hello@oybc.com.</p>`
      ));
      return;
    }
    res.status(200).send(unsubscribePage(
      `<h1 style="font-size:22px;margin:0 0 10px">Leave the list?</h1>` +
      `<p style="font-size:14px;line-height:1.5;color:#7e7460;margin:0 0 20px">` +
      `You won't hear from us when OYBC opens.</p>` +
      `<form method="POST" action="/unsubscribe?u=${token}">` +
      `<button type="submit" style="background:#eb4d2e;color:#fbf6ea;border:2px solid #18120b;` +
      `border-radius:999px;padding:11px 22px;font-weight:800;font-size:14px;letter-spacing:1px;cursor:pointer">` +
      `Take me off the list</button></form>`
    ));
    return;
  }

  if (req.method === "POST") {
    if (validToken) {
      try {
        const db = getFirestore();
        const ref = db.collection("signups").doc(token);
        // Transactional exists-check: never CREATE a doc for an unknown token
        // (that would let the endpoint be used to seed junk rows).
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(ref);
          if (snap.exists) {
            tx.set(ref, {
              unsubscribed: true,
              unsubscribedAt: FieldValue.serverTimestamp(),
            }, { merge: true });
          }
        });
      } catch (err) {
        logger.error("unsubscribe failed", err);
        res.status(500).send(unsubscribePage(
          `<h1 style="font-size:22px;margin:0 0 10px">Something went wrong.</h1>` +
          `<p style="font-size:14px;line-height:1.5;color:#7e7460;margin:0">` +
          `Try the link again, or write to hello@oybc.com.</p>`
        ));
        return;
      }
    }
    res.status(200).send(unsubscribePage(
      `<h1 style="font-size:22px;margin:0 0 10px">You're off the list.</h1>` +
      `<p style="font-size:14px;line-height:1.5;color:#7e7460;margin:0">` +
      `No hard feelings. The doors open ${SEASON} either way — ` +
      `<a href="https://oybc.com" style="color:#eb4d2e;font-weight:bold;text-decoration:none">oybc.com</a>.</p>`
    ));
    return;
  }

  res.status(405).send("method_not_allowed");
});

/**
 * Sends the one-time "you're on the list" confirmation. Best-effort: callers
 * MUST NOT fail the signup if this throws — the address is already stored, and
 * a mail hiccup (or an unverified Resend domain pre-launch) shouldn't surface an
 * error to the user or drop them from the list.
 */
async function sendConfirmationEmail(email: string, emailKey: string): Promise<void> {
  const resend = new Resend(RESEND_API_KEY.value());
  const unsubscribeUrl = `${PUBLIC_ORIGIN}/unsubscribe?u=${emailKey}`;
  const { error } = await resend.emails.send({
    from: CONFIRM_FROM,
    to: email,
    subject: "You're on the board — OYBC",
    // RFC 8058 one-click + classic header — makes Gmail/Apple Mail surface
    // their native "Unsubscribe" affordance next to the sender.
    headers: {
      "List-Unsubscribe": `<${unsubscribeUrl}>`,
      "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
    },
    text: confirmationEmailText(SEASON, unsubscribeUrl),
    html: confirmationEmailHtml(SEASON, unsubscribeUrl),
  });
  if (error) throw new Error(`resend_error: ${error.message ?? error.name}`);
}

/**
 * HTTPS endpoint for the standalone Coming Soon page's email capture. Firebase
 * Hosting rewrites `/api/subscribe` here, so the page calls it same-origin (no
 * CORS) with a plain `fetch` — no Firebase SDK ships to the placeholder.
 *
 * Writes `signups/{emailKey}` where `emailKey` is a SHA-256 of the lowercased
 * email — deterministic (so re-submits are idempotent merge overwrites, and a
 * known address always returns success rather than an error) and doc-id-safe
 * (a raw email can contain `/`, which would break the Firestore path). The
 * readable address is kept in the `email` field. `firestore.rules` denies all
 * client access to `signups`; the Admin SDK here bypasses rules and is the only
 * writer.
 *
 * On a genuinely new signup it sends a one-time confirmation email via Resend
 * (best-effort — a send failure never fails the request or drops the address).
 * Re-submitting a known address is a no-op merge and does NOT re-send, so
 * duplicates never get spammed.
 *
 * Spam control is a hidden honeypot field (`hp`): if it's filled, we return
 * success WITHOUT writing, so bots aren't tipped off. Double opt-in, unsubscribe,
 * and per-IP rate limiting are deferred to launch (they need list management).
 */
export const subscribe = onRequest({ secrets: [RESEND_API_KEY] }, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).json({ ok: false, error: "method_not_allowed" });
    return;
  }

  const body = (req.body ?? {}) as { email?: unknown; source?: unknown; hp?: unknown };
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const source = typeof body.source === "string" ? body.source : "coming-soon";
  const honeypot = typeof body.hp === "string" ? body.hp : "";

  // Honeypot tripped → pretend success, write nothing.
  if (honeypot.length > 0) {
    res.status(200).json({ ok: true });
    return;
  }

  if (!EMAIL_RE.test(email) || email.length > 320) {
    res.status(400).json({ ok: false, error: "invalid_email" });
    return;
  }

  try {
    const db = getFirestore();
    const emailKey = createHash("sha256").update(email).digest("hex");
    const ref = db.collection("signups").doc(emailKey);
    // Read-check-write in a transaction so two concurrent first-time submits of
    // the same address can't both observe it as new and double-send the
    // confirmation (onRequest serves requests concurrently, and there's no rate
    // limit yet). Firestore retries the losing transaction, so exactly one sees
    // exists===false. Also preserves the original createdAt on re-submits (the
    // merge omits createdAt when the doc already exists).
    const isNew = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const exists = snap.exists;
      const data: Record<string, unknown> = { email, source };
      if (!exists) data.createdAt = FieldValue.serverTimestamp();
      // Re-signup after an unsubscribe is an explicit opt-back-in: clear the
      // flag or the launch send's `unsubscribed != true` filter would silently
      // exclude them forever despite the success UI (review finding on #388).
      // Deliberately does NOT re-send the confirmation (isNew stays false) —
      // no re-send loop for repeated submits.
      if (exists && snap.data()?.unsubscribed === true) {
        data.unsubscribed = false;
        data.unsubscribedAt = FieldValue.delete();
      }
      tx.set(ref, data, { merge: true });
      return !exists;
    });

    // Best-effort confirmation — never let a mail failure fail the signup.
    if (isNew) {
      try {
        await sendConfirmationEmail(email, emailKey);
      } catch (mailErr) {
        logger.error(`confirmation email failed for a new signup`, mailErr);
      }
    }

    res.status(200).json({ ok: true });
  } catch (err) {
    logger.error("subscribe failed", err);
    res.status(500).json({ ok: false, error: "internal" });
  }
});

/**
 * Safety-net trigger: if an Auth user is deleted by any path, purge their
 * Firestore data too. Catches cases the callable can't (console/admin deletion,
 * or a client that died after `user.delete()` but before/around the callable).
 */
export const onUserDeleted = functionsV1
  .runWith({ failurePolicy: true }) // retry on transient failure (purge is idempotent)
  .auth.user()
  .onDelete(async (user) => {
    // Let errors propagate so the retry policy can re-run the purge; logging
    // first preserves visibility into what failed.
    try {
      await purgeUserData(user.uid);
    } catch (err) {
      logger.error(`onUserDeleted purge failed for ${user.uid}; will retry`, err);
      throw err;
    }
  });

/**
 * Where the new-signup owner notification goes. Env-overridable for tests /
 * future change without a code edit.
 */
const NOTIFY_TO = process.env.NOTIFY_TO || "2014shea.s@gmail.com";

/**
 * Launch-push delight: email the owner whenever someone genuinely NEW joins
 * the launch list. Fires on document CREATE only — `subscribe`'s re-signup
 * path and `unsubscribe` both merge onto EXISTING docs (never create), and
 * the honeypot branch writes nothing, so every event here is a real first
 * signup. Best-effort: a notify failure only logs — it can never affect the
 * subscriber-facing flow (it runs out-of-band from the request entirely).
 *
 * The count is the aggregate total of `signups` docs (unsubscribed rows
 * included — it's a "list size" vanity number, not the launch-send audience;
 * the send-time filter stays `unsubscribed != true`).
 */
export const onSignupCreated = onDocumentCreated(
  { document: "signups/{key}", secrets: [RESEND_API_KEY] },
  async (event) => {
    // Emulator gate (review finding on #393): the test suites seed signups
    // docs directly, and without this every seed would fire a REAL network
    // call to api.resend.com from CI — flakiness surface for zero coverage
    // (the builder is unit-tested; the wiring is production-verified).
    if (process.env.FUNCTIONS_EMULATOR === "true") {
      logger.info("signup notification skipped (emulator)");
      return;
    }
    try {
      const data = event.data?.data();
      const email = typeof data?.email === "string" ? data.email : "(unknown)";
      const source = typeof data?.source === "string" ? data.source : "(unknown)";

      const agg = await getFirestore().collection("signups").count().get();
      const count = agg.data().count;

      const note = buildSignupNotification(email, source, count);
      const resend = new Resend(RESEND_API_KEY.value());
      const { error } = await resend.emails.send({
        from: CONFIRM_FROM,
        to: NOTIFY_TO,
        subject: note.subject,
        text: note.text,
        html: note.html,
      });
      if (error) throw new Error(`resend_error: ${error.message ?? error.name}`);
    } catch (err) {
      logger.error("signup notification failed", err);
    }
  },
);
