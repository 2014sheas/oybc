/**
 * Emulator-backed test for the recursive-purge logic that backs both
 * `onUserDeleted` and `deleteUserData` (see `functions/src/index.ts`).
 *
 * Invokes `purgeUserData` directly — no Functions emulator, no auth
 * complexity — against a real Firestore emulator instance. Must be run via
 * `firebase emulators:exec --only functions,firestore` (see
 * `functions/package.json`'s `test` script) so `FIRESTORE_EMULATOR_HOST` is
 * set; without a reachable emulator these tests fail on connection refused,
 * not on assertion mismatches.
 *
 * Import order matters: `../src/index` is imported before
 * `firebase-admin/firestore` because `src/index.ts` calls the Admin SDK's
 * `initializeApp()` (no args) at module-load time — the same call used in
 * production. Importing it first guarantees the default app exists before
 * this file calls `getFirestore()` for its own seed/assert calls, avoiding a
 * "default app already exists" double-init error.
 */
import { describe, it, expect } from "vitest";
import { purgeUserData } from "../src/index";
import { getFirestore } from "firebase-admin/firestore";

const db = getFirestore();

describe("purgeUserData", () => {
  it("deletes the target user's parent doc + subcollections, leaves other users untouched", async () => {
    const targetUid = `purge-target-${Date.now()}`;
    const otherUid = `purge-other-${Date.now()}`;

    await db.doc(`users/${targetUid}`).set({ id: targetUid, version: 1 });
    await db
      .doc(`users/${targetUid}/boards/board-1`)
      .set({ userId: targetUid, name: "Board 1" });
    await db
      .doc(`users/${targetUid}/boards/board-2`)
      .set({ userId: targetUid, name: "Board 2" });
    await db
      .doc(`users/${targetUid}/tasks/task-1`)
      .set({ userId: targetUid, title: "Task 1" });

    await db.doc(`users/${otherUid}`).set({ id: otherUid, version: 1 });
    await db
      .doc(`users/${otherUid}/boards/board-1`)
      .set({ userId: otherUid, name: "Other user's board" });

    await purgeUserData(targetUid);

    const targetUserDoc = await db.doc(`users/${targetUid}`).get();
    expect(targetUserDoc.exists).toBe(false);

    const targetBoards = await db
      .collection(`users/${targetUid}/boards`)
      .get();
    expect(targetBoards.empty).toBe(true);

    const targetTasks = await db.collection(`users/${targetUid}/tasks`).get();
    expect(targetTasks.empty).toBe(true);

    // The second user's tree must be completely unaffected.
    const otherUserDoc = await db.doc(`users/${otherUid}`).get();
    expect(otherUserDoc.exists).toBe(true);
    expect(otherUserDoc.data()).toEqual({ id: otherUid, version: 1 });

    const otherBoards = await db.collection(`users/${otherUid}/boards`).get();
    expect(otherBoards.empty).toBe(false);
    expect(otherBoards.docs).toHaveLength(1);
    expect(otherBoards.docs[0].data()).toEqual({
      userId: otherUid,
      name: "Other user's board",
    });
  });

  it("is idempotent — purging a user with no Firestore data is a no-op, not an error", async () => {
    const neverExistedUid = `purge-absent-${Date.now()}`;

    await expect(purgeUserData(neverExistedUid)).resolves.toBeUndefined();

    const doc = await db.doc(`users/${neverExistedUid}`).get();
    expect(doc.exists).toBe(false);
  });
});
