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

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import * as functionsV1 from "firebase-functions/v1";
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

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
