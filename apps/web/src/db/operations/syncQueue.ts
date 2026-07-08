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
