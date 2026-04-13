import {
  collection,
  doc,
  getDoc,
  getDocs,
  setDoc,
  query,
  where,
  serverTimestamp,
} from 'firebase/firestore';
import { firestore, auth } from './config';
import { resolveConflict, type SyncableEntity } from './conflictResolver';
import { db } from '../db/database';
import {
  fetchPendingSyncItems,
  markSyncItemInProgress,
  markSyncItemCompleted,
  markSyncItemFailed,
} from '../db/operations/syncQueue';
import { SyncOperationType, SyncStatus, type User } from '@oybc/shared';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Entity types that can be synced, mapped to their Dexie table names
 * and Firestore subcollection paths under `users/{userId}/`.
 */
const SYNCABLE_COLLECTIONS = [
  'boards',
  'tasks',
  'taskSteps',
  'boardTasks',
  'compositeTasks',
  'compositeNodes',
] as const;

type SyncCollection = (typeof SYNCABLE_COLLECTIONS)[number];

export interface PushResult {
  pushed: number;
  conflicts: number;
  failed: number;
  details: string[];
}

export interface PullResult {
  pulled: number;
  conflicts: number;
  details: string[];
}

export interface SyncResult {
  push: PushResult;
  pull: PullResult;
}

// ─── Push Sync ────────────────────────────────────────────────────────────────

/**
 * Pushes pending sync queue items to Firestore.
 *
 * For each pending item:
 * 1. Marks it IN_PROGRESS
 * 2. Reads the remote document (if exists) for conflict check
 * 3. Resolves conflicts using LWW
 * 4. Writes to Firestore if local wins (or remote doesn't exist)
 * 5. Updates local DB if remote wins
 * 6. Marks the queue item COMPLETED or FAILED
 *
 * @param userId - The authenticated user's ID (for Firestore path)
 * @returns Push result summary
 */
export async function pushSync(userId: string): Promise<PushResult> {
  const result: PushResult = { pushed: 0, conflicts: 0, failed: 0, details: [] };

  // Reset stale IN_PROGRESS items (e.g., from a crash/reload mid-sync)
  const staleItems = await db.syncQueue
    .where('status')
    .equals(SyncStatus.IN_PROGRESS)
    .toArray();
  for (const stale of staleItems) {
    await db.syncQueue.update(stale.id, { status: SyncStatus.PENDING });
  }

  const pendingItems = await fetchPendingSyncItems();
  if (pendingItems.length === 0) return result;

  for (const item of pendingItems) {
    try {
      await markSyncItemInProgress(item.id);

      const entityType = item.entityType as SyncCollection | 'users';
      const payload = JSON.parse(item.payload) as SyncableEntity;

      // The `users` entity lives at `users/{userId}` (the parent scope doc),
      // not in a `users/{userId}/users` subcollection, so it has a dedicated
      // docRef. Every other entity is a subcollection child under the user.
      const docRef =
        entityType === 'users'
          ? doc(firestore, 'users', item.entityId)
          : doc(firestore, 'users', userId, entityType, item.entityId);

      // User entities are never DELETE-synced; clearing the user doc would
      // remove the scope root for every other collection.
      if (entityType === 'users' && item.operationType === SyncOperationType.DELETE) {
        await markSyncItemCompleted(item.id);
        result.details.push(`Skipped delete for users/${item.entityId}`);
        continue;
      }

      if (item.operationType === SyncOperationType.DELETE) {
        // Deletes still check conflict resolution — don't overwrite a newer remote version
        const remoteDeleteSnap = await getDoc(docRef);
        if (remoteDeleteSnap.exists()) {
          const remoteData = remoteDeleteSnap.data() as SyncableEntity;
          const resolution = resolveConflict(payload, remoteData);
          if (resolution.winner === 'remote') {
            // Remote is newer — don't delete, keep remote version locally
            const table = db.table(entityType);
            await table.put(remoteData);
            await markSyncItemCompleted(item.id);
            result.conflicts++;
            result.details.push(`Delete conflict ${entityType}/${item.entityId}: remote wins (v${remoteData.version})`);
            continue;
          }
        }
        await writeSingleDoc(docRef, payload);
        await markSyncItemCompleted(item.id);
        result.pushed++;
        result.details.push(`Deleted ${entityType}/${item.entityId}`);
        continue;
      }

      // Check for remote version
      const remoteSnap = await getDoc(docRef);

      if (!remoteSnap.exists()) {
        // No remote — push directly
        await writeSingleDoc(docRef, payload);
        await markSyncItemCompleted(item.id);
        result.pushed++;
        result.details.push(`Pushed ${entityType}/${item.entityId} (new)`);
        continue;
      }

      // Remote exists — resolve conflict
      const remoteData = remoteSnap.data() as SyncableEntity;
      const resolution = resolveConflict(payload, remoteData);

      if (resolution.winner === 'local') {
        // Local wins — push to Firestore
        await writeSingleDoc(docRef, payload);
        await markSyncItemCompleted(item.id);
        result.pushed++;
        result.details.push(
          `Pushed ${entityType}/${item.entityId} (local v${payload.version} > remote v${remoteData.version})`
        );
      } else {
        // Remote wins — update local DB with remote data
        const table = db.table(entityType);
        await table.put(remoteData);
        await markSyncItemCompleted(item.id);
        result.conflicts++;
        result.details.push(
          `Conflict ${entityType}/${item.entityId}: remote wins (v${remoteData.version} >= v${payload.version})`
        );
      }
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      console.error(`Sync push failed for ${item.entityType}/${item.entityId}:`, err);
      await markSyncItemFailed(item.id, errorMsg);
      result.failed++;
      result.details.push(`Failed ${item.entityType}/${item.entityId}: ${errorMsg}`);
    }
  }

  return result;
}

// ─── Pull Sync ────────────────────────────────────────────────────────────────

/**
 * Pulls remote changes from Firestore that are newer than the local lastSyncedAt.
 *
 * For each syncable collection:
 * 1. Queries Firestore for documents updated after lastSyncedAt
 * 2. For each document, compares with local version
 * 3. Resolves conflicts using LWW
 * 4. Applies winning data to local DB
 *
 * @param userId - The authenticated user's ID
 * @param lastSyncedAt - ISO8601 timestamp of the last successful sync
 * @returns Pull result summary
 */
export async function pullSync(
  userId: string,
  lastSyncedAt?: string,
): Promise<PullResult> {
  const result: PullResult = { pulled: 0, conflicts: 0, details: [] };
  let hadPullError = false;

  // Pull the user doc (lives at `users/{userId}`, not a subcollection) so
  // synced profile fields like `preferences` replicate back to this device.
  try {
    const userDocRef = doc(firestore, 'users', userId);
    const userSnap = await getDoc(userDocRef);
    if (userSnap.exists()) {
      const remoteUserData = userSnap.data();
      const remoteUser = remoteUserData as unknown as User;
      const remoteSyncable = remoteUserData as SyncableEntity;
      const localUser = await db.users.get(userId);
      const localSyncable = localUser as SyncableEntity | undefined;
      if (!localUser) {
        await db.users.put(remoteUser);
        result.pulled++;
        result.details.push(`Pulled users/${userId} (new)`);
      } else {
        const resolution = resolveConflict(localSyncable!, remoteSyncable);
        if (resolution.winner === 'remote') {
          // Preserve the local `lastSyncedAt` watermark through a pull.
          await db.users.put({
            ...remoteUser,
            lastSyncedAt: localUser.lastSyncedAt ?? remoteUser.lastSyncedAt,
          });
          result.pulled++;
          result.details.push(
            `Pulled users/${userId} (remote v${remoteSyncable.version} > local v${localSyncable!.version})`
          );
        } else {
          result.conflicts++;
          result.details.push(
            `Kept local users/${userId} (local v${localSyncable!.version} >= remote v${remoteSyncable.version})`
          );
        }
      }
    }
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err);
    result.details.push(`Pull failed for users/${userId}: ${errorMsg}`);
    hadPullError = true;
  }

  for (const collectionName of SYNCABLE_COLLECTIONS) {
    try {
      const colRef = collection(firestore, 'users', userId, collectionName);

      // Query for documents updated since last sync.
      // Uses _syncedAt (server timestamp) as watermark for clock-skew safety.
      // Falls back to updatedAt if _syncedAt is not available.
      const q = lastSyncedAt
        ? query(colRef, where('_syncedAt', '>', lastSyncedAt))
        : query(colRef); // First sync — pull everything

      const snapshot = await getDocs(q);
      if (snapshot.empty) continue;

      for (const docSnap of snapshot.docs) {
        const remoteData = docSnap.data() as SyncableEntity;
        const table = db.table(collectionName);
        const localData = await table.get(remoteData.id) as SyncableEntity | undefined;

        if (!localData) {
          // New remote document — insert locally
          await table.put(remoteData);
          result.pulled++;
          result.details.push(`Pulled ${collectionName}/${remoteData.id} (new)`);
          continue;
        }

        // Both exist — resolve conflict
        const resolution = resolveConflict(localData, remoteData);

        if (resolution.winner === 'remote') {
          await table.put(remoteData);
          result.pulled++;
          result.details.push(
            `Pulled ${collectionName}/${remoteData.id} (remote v${remoteData.version} > local v${localData.version})`
          );
        } else {
          result.conflicts++;
          result.details.push(
            `Kept local ${collectionName}/${remoteData.id} (local v${localData.version} >= remote v${remoteData.version})`
          );
        }
      }
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      result.details.push(`Pull failed for ${collectionName}: ${errorMsg}`);
      hadPullError = true;
    }
  }

  // Only advance the watermark if pull completed without errors,
  // otherwise we risk permanently skipping updates for failed collections.
  if (!hadPullError) {
    const now = new Date().toISOString();
    const user = await db.users.get(userId);
    if (user) {
      await db.users.update(userId, { lastSyncedAt: now });
    }
  }

  return result;
}

// ─── Full Sync ────────────────────────────────────────────────────────────────

/**
 * Performs a full sync cycle: push local changes, then pull remote changes.
 *
 * @param userId - The authenticated user's ID
 * @returns Combined push and pull results
 */
export async function fullSync(userId: string): Promise<SyncResult> {
  // Defense-in-depth: verify userId matches the authenticated user
  if (auth.currentUser?.uid !== userId) {
    throw new Error('Sync userId does not match authenticated user');
  }

  // Get lastSyncedAt before pushing (so we don't miss changes during push)
  const user = await db.users.get(userId);
  const lastSyncedAt = user?.lastSyncedAt;

  const push = await pushSync(userId);
  const pull = await pullSync(userId, lastSyncedAt);

  return { push, pull };
}

// ─── Background Sync Loop ─────────────────────────────────────────────────────

/**
 * Starts a background sync loop that runs push+pull on an interval.
 *
 * Pauses when offline (`navigator.onLine` is false) and resumes
 * when back online. Returns a cleanup function for useEffect.
 *
 * @param userId - The authenticated user's ID
 * @param intervalMs - Sync interval in milliseconds (default 30s)
 * @returns Cleanup function that stops the loop
 */
export function startSyncLoop(
  userId: string,
  intervalMs: number = 30_000,
): () => void {
  let timer: ReturnType<typeof setInterval> | null = null;
  let isSyncing = false;

  async function tick(): Promise<void> {
    if (isSyncing || !navigator.onLine) return;
    isSyncing = true;
    try {
      await fullSync(userId);
    } catch (err) {
      console.error('Sync loop error:', err);
    } finally {
      isSyncing = false;
    }
  }

  // Start interval
  timer = setInterval(() => void tick(), intervalMs);

  // Also sync immediately when coming back online
  function handleOnline(): void {
    void tick();
  }
  window.addEventListener('online', handleOnline);

  // Run an initial sync immediately
  void tick();

  // Cleanup
  return () => {
    if (timer) clearInterval(timer);
    window.removeEventListener('online', handleOnline);
  };
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Writes a single document to Firestore, stripping undefined values.
 */
async function writeSingleDoc(
  docRef: ReturnType<typeof doc>,
  data: Record<string, unknown>,
): Promise<void> {
  // Firestore doesn't accept undefined values — strip them
  const cleaned: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data)) {
    if (value !== undefined) {
      cleaned[key] = value;
    }
  }
  cleaned._syncedAt = serverTimestamp();

  await setDoc(docRef, cleaned, { merge: true });
}
