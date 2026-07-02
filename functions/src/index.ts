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
import { createHash } from "crypto";
import { Resend } from "resend";

initializeApp();

/**
 * Recursively deletes a user's parent doc and every subcollection beneath it
 * (`users/{uid}` + boards/tasks/boardTasks/compoundChildren/... ). Idempotent:
 * deleting already-absent docs is a no-op.
 */
async function purgeUserData(uid: string): Promise<void> {
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
 * Sends the one-time "you're on the list" confirmation. Best-effort: callers
 * MUST NOT fail the signup if this throws — the address is already stored, and
 * a mail hiccup (or an unverified Resend domain pre-launch) shouldn't surface an
 * error to the user or drop them from the list.
 */
async function sendConfirmationEmail(email: string): Promise<void> {
  const resend = new Resend(RESEND_API_KEY.value());
  const { error } = await resend.emails.send({
    from: CONFIRM_FROM,
    to: email,
    subject: "You're on the board — OYBC",
    text:
      `You're on the board.\n\n` +
      `Thanks for signing up. We'll email you the moment OYBC opens — ${SEASON}. ` +
      `That's a bingo.\n\n` +
      `You're getting this because you asked to be notified at oybc.com. ` +
      `We'll only email you at launch.\n\n` +
      `— OYBC · On Your Bingo Card`,
    html:
      `<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;` +
      `max-width:480px;margin:0 auto;padding:24px;color:#18120b">` +
      `<h1 style="font-size:22px;margin:0 0 12px">You're on the board.</h1>` +
      `<p style="font-size:15px;line-height:1.5;margin:0 0 16px">` +
      `Thanks for signing up. We'll email you the moment OYBC opens — <b>${SEASON}</b>. That's a bingo.` +
      `</p>` +
      `<p style="font-size:12.5px;line-height:1.5;color:#7e7460;margin:0">` +
      `You're getting this because you asked to be notified at ` +
      `<a href="https://oybc.com" style="color:#eb4d2e">oybc.com</a>. We'll only email you at launch.` +
      `</p>` +
      `<p style="font-size:12.5px;color:#7e7460;margin:16px 0 0">— OYBC · On Your Bingo Card</p>` +
      `</div>`,
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
      const exists = (await tx.get(ref)).exists;
      const data: Record<string, unknown> = { email, source };
      if (!exists) data.createdAt = FieldValue.serverTimestamp();
      tx.set(ref, data, { merge: true });
      return !exists;
    });

    // Best-effort confirmation — never let a mail failure fail the signup.
    if (isNew) {
      try {
        await sendConfirmationEmail(email);
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
