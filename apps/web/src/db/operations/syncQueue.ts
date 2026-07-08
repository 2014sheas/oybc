import { db } from '../internal';
import type { SyncQueueItem } from '@oybc/shared';
import {
  MAX_SYNC_RETRIES,
  SyncOperationType,
  SyncStatus,
  isFailedItemEligibleForRetry,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * SyncQueue Operations
 */

/**
 * Add item to sync queue
 */
export async function addToSyncQueue(
  entityType: string,
  entityId: string,
  operationType: SyncOperationType,
  payload: unknown,
  priority: number = 0
): Promise<void> {
  // Skip sync queue for playground data — prevents cross-user pollution.
  // Gated behind DEV so a production build can never silently swallow a
  // legitimate sync because a user happens to match the sentinel string.
  if (import.meta.env.DEV) {
    const payloadObj = payload as Record<string, unknown> | null;
    if (payloadObj?.userId === 'playground-user-1') return;
  }

  const item: SyncQueueItem = {
    id: generateUUID(),
    entityType,
    entityId,
    operationType,
    payload: JSON.stringify(payload),
    status: SyncStatus.PENDING,
    retryCount: 0,
    createdAt: currentTimestamp(),
    priority,
  };

  await db.syncQueue.add(item);
}

/**
 * Fetch pending sync items (ordered by priority and creation time)
 */
/**
 * Fetch every sync-queue item regardless of status.
 *
 * Used by the dev sync-simulation playground to render the raw queue. The
 * production sync loop uses `fetchPendingSyncItems` (status-filtered).
 *
 * @returns All SyncQueueItem rows.
 */
export async function fetchAllSyncQueueItems(): Promise<SyncQueueItem[]> {
  return db.syncQueue.toArray();
}

export async function fetchPendingSyncItems(): Promise<SyncQueueItem[]> {
  return db.syncQueue
    .where('[status+priority+createdAt]')
    .between(
      [SyncStatus.PENDING, 0, ''],
      [SyncStatus.PENDING, Infinity, '\uffff']
    )
    .reverse()
    .toArray();
}

/**
 * Mark sync item as in progress
 */
export async function markSyncItemInProgress(id: string): Promise<void> {
  await db.syncQueue.update(id, {
    status: SyncStatus.IN_PROGRESS,
    lastAttemptAt: currentTimestamp(),
  });
}

/**
 * Mark sync item as completed
 */
export async function markSyncItemCompleted(id: string): Promise<void> {
  await db.syncQueue.update(id, {
    status: SyncStatus.COMPLETED,
    completedAt: currentTimestamp(),
  });
}

/**
 * The shared-counter ancestor bookkeeping that must land atomically with a
 * successful counting-task push: advance `lastSyncedCount` to the value just
 * pushed to Firestore, so the next conflict can compute the local delta.
 */
export interface CountAdvance {
  /** The counting task's id. */
  taskId: string;
  /** The `currentCount` value just pushed to Firestore. */
  pushedCount: number;
}

/**
 * Atomically mark a pushed sync-queue item COMPLETED and — for a counting
 * task — advance its `lastSyncedCount` to the pushed value, in ONE Dexie
 * transaction over `syncQueue` + `tasks`.
 *
 * D2 (issue #294): the `lastSyncedCount` advance used to run as a separate
 * write that swallowed its own failure, silently downgrading the NEXT
 * shared-counter conflict from additive merge to increment-losing LWW.
 * Folding it into the queue-completion transaction closes that window — both
 * writes commit together or neither does. If the transaction fails it
 * propagates to the push loop, which marks the item FAILED and retries; the
 * advance is idempotent (sets the common ancestor := pushed value), so the
 * retry re-applies it cleanly. Passing `null` for a non-counting push makes
 * this a plain queue-completion.
 *
 * @param queueItemId - The sync-queue item to mark completed.
 * @param countAdvance - The counting-task ancestor advance, or `null`.
 * @param testHooks - Test-only seam. `beforeCountAdvance` runs inside the
 *   transaction just before the count write, letting a test force a
 *   mid-transaction failure to prove atomic rollback. Never passed in prod.
 */
export async function completePushedItem(
  queueItemId: string,
  countAdvance: CountAdvance | null,
  testHooks?: { beforeCountAdvance?: () => void | Promise<void> },
): Promise<void> {
  await db.transaction('rw', [db.syncQueue, db.tasks], async () => {
    await db.syncQueue.update(queueItemId, {
      status: SyncStatus.COMPLETED,
      completedAt: currentTimestamp(),
    });
    if (testHooks?.beforeCountAdvance) {
      await testHooks.beforeCountAdvance();
    }
    if (countAdvance) {
      await db.tasks.update(countAdvance.taskId, {
        lastSyncedCount: countAdvance.pushedCount,
      });
    }
  });
}

/**
 * Mark sync item as failed
 */
export async function markSyncItemFailed(
  id: string,
  error: string
): Promise<void> {
  const item = await db.syncQueue.get(id);
  if (!item) return;

  await db.syncQueue.update(id, {
    status: SyncStatus.FAILED,
    retryCount: item.retryCount + 1,
    lastError: error,
    lastAttemptAt: currentTimestamp(),
  });
}

/**
 * Delete sync item
 */
export async function deleteSyncItem(id: string): Promise<void> {
  await db.syncQueue.delete(id);
}

/**
 * Clear completed sync items
 */
export async function clearCompletedSyncItems(): Promise<void> {
  await db.syncQueue.where('status').equals(SyncStatus.COMPLETED).delete();
}

/**
 * Promote FAILED sync queue items back to PENDING when their backoff
 * window has elapsed and they're under the retry cap.
 *
 * Called at the top of `pushSync`. The Dexie `liveQuery` on the PENDING
 * count re-fires when items are promoted, which in turn triggers the
 * push-on-enqueue debounce — so promotion implicitly schedules a fresh
 * push attempt without needing an explicit kick.
 *
 * Items at or above `MAX_SYNC_RETRIES` are left FAILED indefinitely;
 * they require a fresh enqueue or a manual retry from the playground
 * dashboard. (Tracked separately if real users hit this in the wild.)
 *
 * @returns The number of items promoted.
 */
export async function promoteEligibleFailedItems(): Promise<number> {
  const failedItems = await db.syncQueue
    .where('status')
    .equals(SyncStatus.FAILED)
    .toArray();

  const now = Date.now();
  let promoted = 0;

  for (const item of failedItems) {
    if (item.retryCount >= MAX_SYNC_RETRIES) {
      // Item has exhausted retries — warn once per promote cycle so a
      // wedged queue is visible in devtools rather than silently
      // abandoned. `result.details` downstream still surfaces the
      // FAILED state in the playground dashboard.
      console.warn(
        `[sync] ${item.entityType}/${item.entityId} abandoned after ${item.retryCount} retries; last error: ${item.lastError ?? 'unknown'}`
      );
      continue;
    }
    const lastAttemptAtMs = item.lastAttemptAt
      ? new Date(item.lastAttemptAt).getTime()
      : null;
    if (!isFailedItemEligibleForRetry(item.retryCount, lastAttemptAtMs, now)) continue;

    await db.syncQueue.update(item.id, {
      status: SyncStatus.PENDING,
      lastError: undefined,
    });
    promoted++;
  }

  return promoted;
}

/**
 * Count FAILED sync-queue items that have exhausted their retry budget
 * (`retryCount >= MAX_SYNC_RETRIES`). These are exactly the items
 * `promoteEligibleFailedItems` refuses to re-promote — they sit FAILED
 * until a manual or network-regain retry recovers them.
 *
 * Cheap: a single full-table scan + in-memory count. The sync queue only
 * holds unsynced/failed rows (COMPLETED items are cleared), so it stays
 * small. Scans rather than `where('status')` because `status` has no
 * standalone Dexie index (only the `[status+priority+createdAt]` compound),
 * so an equality query on it would need compound-index emulation. Refreshed
 * onto the sync status after every push cycle so the UI can surface
 * "N changes couldn't sync".
 *
 * @returns The number of exhausted FAILED items.
 */
export async function countExhaustedSyncItems(): Promise<number> {
  const all = await db.syncQueue.toArray();
  return all.reduce(
    (n, item) =>
      item.status === SyncStatus.FAILED && item.retryCount >= MAX_SYNC_RETRIES
        ? n + 1
        : n,
    0
  );
}

/**
 * Reset every exhausted FAILED item back to a fresh PENDING state:
 * `retryCount → 0`, `lastError` cleared, `status → PENDING`. This gives
 * the regular backoff/promote machinery a clean slate to retry them.
 *
 * Setting items to PENDING re-fires the Dexie `liveQuery` on the PENDING
 * count (see `startSyncLoop`), which schedules a debounced push — so this
 * implicitly nudges a push cycle without importing the firebase-coupled
 * sync loop here (keeping this module firebase-free and unit-testable).
 * Callers wanting an immediate push (the manual Retry button, the
 * network-regain kick) additionally invoke `fullSync`.
 *
 * @returns The number of items reset.
 */
export async function retryExhaustedSyncItems(): Promise<number> {
  // One transaction so a reload mid-reset can't leave a partial batch
  // (mirrors the iOS twin's single write block). Idempotent either way,
  // but atomic beats self-healing.
  return db.transaction('rw', [db.syncQueue], async () => {
    const all = await db.syncQueue.toArray();
    const exhausted = all.filter(
      (item) =>
        item.status === SyncStatus.FAILED && item.retryCount >= MAX_SYNC_RETRIES
    );
    for (const item of exhausted) {
      await db.syncQueue.update(item.id, {
        status: SyncStatus.PENDING,
        retryCount: 0,
        lastError: undefined,
      });
    }
    return exhausted.length;
  });
}
