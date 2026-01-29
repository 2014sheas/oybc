import { db } from '../database';
import type { SyncQueueItem } from '@oybc/shared';
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
  operationType: 'create' | 'update' | 'delete',
  payload: unknown,
  priority: number = 0
): Promise<void> {
  const item: SyncQueueItem = {
    id: generateUUID(),
    entityType,
    entityId,
    operationType,
    payload: JSON.stringify(payload),
    status: 'pending',
    retryCount: 0,
    createdAt: currentTimestamp(),
    priority,
  };

  await db.syncQueue.add(item);
}

/**
 * Fetch pending sync items (ordered by priority and creation time)
 */
export async function fetchPendingSyncItems(): Promise<SyncQueueItem[]> {
  return db.syncQueue
    .where('[status+priority+createdAt]')
    .between(
      ['pending', 0, ''],
      ['pending', Infinity, '\uffff']
    )
    .reverse()
    .toArray();
}

/**
 * Mark sync item as in progress
 */
export async function markSyncItemInProgress(id: string): Promise<void> {
  await db.syncQueue.update(id, {
    status: 'in_progress',
    lastAttemptAt: currentTimestamp(),
  });
}

/**
 * Mark sync item as completed
 */
export async function markSyncItemCompleted(id: string): Promise<void> {
  await db.syncQueue.update(id, {
    status: 'completed',
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
    status: 'failed',
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
  await db.syncQueue.where('status').equals('completed').delete();
}

/**
 * Retry failed sync items
 */
export async function retryFailedSyncItems(): Promise<void> {
  const failedItems = await db.syncQueue
    .where('status')
    .equals('failed')
    .filter((item) => item.retryCount < 3)
    .toArray();

  for (const item of failedItems) {
    await db.syncQueue.update(item.id, {
      status: 'pending',
      lastError: undefined,
    });
  }
}
