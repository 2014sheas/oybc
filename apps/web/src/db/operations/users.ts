import {
  DEFAULT_USER_PREFERENCES,
  SyncOperationType,
  mergeUserPreferences,
  type User,
  type UserPreferences,
} from '@oybc/shared';
import { db } from '../database';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * User Operations
 */

/**
 * Atomically update the authenticated user's synced preferences.
 *
 * Merges `partial` onto the current user's preferences (falling back to
 * DEFAULT_USER_PREFERENCES for any missing fields), bumps `version` +
 * `updatedAt`, and enqueues a `SyncOperationType.UPDATE` entry for the
 * `users` collection — all inside a single Dexie transaction so the write
 * and its sync-queue companion are consistent.
 *
 * @param userId - ID of the User row to update
 * @param partial - Partial preferences object; only the provided fields are overwritten
 * @returns The updated User row, or `undefined` if the row does not exist
 */
export async function updateUserPreferences(
  userId: string,
  partial: Partial<UserPreferences>
): Promise<User | undefined> {
  let result: User | undefined;

  await db.transaction('rw', [db.users, db.syncQueue], async () => {
    const existing = await db.users.get(userId);
    if (!existing) return;

    const mergedPreferences = mergeUserPreferences({
      ...(existing.preferences ?? DEFAULT_USER_PREFERENCES),
      ...partial,
    });

    const updated: User = {
      ...existing,
      preferences: mergedPreferences,
      version: (existing.version ?? 0) + 1,
      updatedAt: currentTimestamp(),
    };

    await db.users.put(updated);
    await addToSyncQueue('users', userId, SyncOperationType.UPDATE, updated);
    result = updated;
  });

  return result;
}

/**
 * Update the user's display name in the local DB and enqueue a sync.
 *
 * This is the local-DB half of a display-name change. The caller is
 * responsible for updating the Firebase Auth profile first (via
 * `updateProfile`) so that the new name shows up on re-authentication.
 *
 * @param userId - ID of the User row
 * @param displayName - New display name; empty string clears it
 * @returns The updated User row, or undefined if not found
 */
export async function updateUserDisplayName(
  userId: string,
  displayName: string
): Promise<User | undefined> {
  let result: User | undefined;

  await db.transaction('rw', [db.users, db.syncQueue], async () => {
    const existing = await db.users.get(userId);
    if (!existing) return;

    // Store the trimmed value (possibly empty string). Using '' instead
    // of `undefined` because: (a) IndexedDB drops undefined properties,
    // (b) Firestore ignores undefined fields in writes — both would
    // silently retain the old value and the onSnapshot listener would
    // overwrite the local clear.
    const updated: User = {
      ...existing,
      displayName,
      version: (existing.version ?? 0) + 1,
      updatedAt: currentTimestamp(),
    };

    await db.users.put(updated);
    await addToSyncQueue('users', userId, SyncOperationType.UPDATE, updated);
    result = updated;
  });

  return result;
}

/**
 * Update the locally-stored email for a user + enqueue a sync.
 *
 * Used by the Account & security email-change reconcile: Firebase's
 * `verifyBeforeUpdateEmail` swaps `currentUser.email` out-of-band (after the
 * user clicks the link in the new inbox), so the local row + Firestore must be
 * healed to the verified address. Mirrors `updateUserDisplayName`.
 *
 * @param userId - ID of the User row to update
 * @param email - The new (verified) email address
 * @returns The updated User row, or `undefined` if the row does not exist
 */
export async function updateUserEmail(
  userId: string,
  email: string
): Promise<User | undefined> {
  let result: User | undefined;

  await db.transaction('rw', [db.users, db.syncQueue], async () => {
    const existing = await db.users.get(userId);
    if (!existing) return;

    const updated: User = {
      ...existing,
      email,
      version: (existing.version ?? 0) + 1,
      updatedAt: currentTimestamp(),
    };

    await db.users.put(updated);
    await addToSyncQueue('users', userId, SyncOperationType.UPDATE, updated);
    result = updated;
  });

  return result;
}
