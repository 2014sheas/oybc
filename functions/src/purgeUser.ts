/**
 * Account-data purge shared by both deletion entry points in `index.ts`
 * (`onUserDeleted` — the primary Auth-trigger path — and the `deleteUserData`
 * callable). Kept in its own module so its write ORDER can be unit-tested
 * against a mocked Admin SDK without loading every other function.
 */
import { logger } from "firebase-functions/v2";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

/** Top-level collection holding one marker doc per deleted account. */
export const DELETED_USERS_COLLECTION = "deletedUsers";

/**
 * Writes the `deletedUsers/{uid}` marker, THEN recursively deletes the user's
 * parent doc and every subcollection beneath it (`users/{uid}` +
 * boards/tasks/boardTasks/compoundChildren/...).
 *
 * The marker must land first: `firestore.rules` refuses every client write
 * under `users/{uid}` once it exists, which closes the window where a deleted
 * user's still-unexpired ID token (second device, in-flight sync push) could
 * re-create docs after the purge — docs nothing would ever purge again. A
 * marker written after the delete would leave that window open during the
 * delete itself.
 *
 * Idempotent: the marker write is a `set` (a retry just refreshes
 * `deletedAt`), and deleting already-absent docs is a no-op — so the v1
 * trigger's `failurePolicy` retries converge.
 *
 * @param uid - Firebase Auth uid of the account being deleted (taken from a
 *   verified auth context or the Auth trigger — never client-supplied).
 * @throws Propagates any Firestore error so the caller can retry/report; if
 *   the marker write fails, nothing is deleted.
 */
export async function purgeUserData(uid: string): Promise<void> {
  const db = getFirestore();
  await db
    .collection(DELETED_USERS_COLLECTION)
    .doc(uid)
    .set({ deletedAt: FieldValue.serverTimestamp() });
  await db.recursiveDelete(db.collection("users").doc(uid));
  logger.info(`Purged Firestore data for user ${uid} (deletedUsers marker written)`);
}
