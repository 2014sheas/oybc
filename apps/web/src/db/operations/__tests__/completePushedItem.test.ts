import { afterEach, describe, expect, it } from 'vitest';
import {
  SyncOperationType,
  SyncStatus,
  type SyncQueueItem,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { completePushedItem } from '../syncQueue';

/**
 * Covers D2 (issue #294): the atomic fold of queue-completion + shared-counter
 * `lastSyncedCount` advancement in `completePushedItem`. The advance used to run
 * as a separate write that swallowed its own failure, silently downgrading the
 * next counter conflict to increment-losing LWW. Folding it into the completion
 * transaction means both writes land together or neither does.
 *
 * Firebase-free: imports only the Dexie singleton (`db`) + `@oybc/shared`, so it
 * runs in the node Vitest harness against `fake-indexeddb`.
 */

function makeQueueItem(overrides: Partial<SyncQueueItem> = {}): SyncQueueItem {
  return {
    id: `item-${Math.random().toString(36).slice(2)}`,
    entityType: 'tasks',
    entityId: 'task-1',
    operationType: SyncOperationType.UPDATE,
    payload: '{}',
    status: SyncStatus.IN_PROGRESS,
    retryCount: 0,
    createdAt: new Date().toISOString(),
    priority: 0,
    ...overrides,
  };
}

function makeCountingTask(overrides: Partial<Task> = {}): Task {
  const now = new Date().toISOString();
  return {
    id: 'task-1',
    userId: 'user-1',
    type: 'counting',
    title: 'Push-ups',
    isCompleted: false,
    currentCount: 12,
    maxCount: 20,
    lastSyncedCount: 3,
    version: 1,
    createdAt: now,
    updatedAt: now,
    isDeleted: false,
    ...overrides,
  } as Task;
}

afterEach(async () => {
  await db.syncQueue.clear();
  await db.tasks.clear();
});

describe('completePushedItem — happy advancement', () => {
  it('marks the item COMPLETED and advances lastSyncedCount to the pushed value', async () => {
    const item = makeQueueItem();
    await db.syncQueue.add(item);
    await db.tasks.add(makeCountingTask({ currentCount: 12, lastSyncedCount: 3 }));

    await completePushedItem(item.id, { taskId: 'task-1', pushedCount: 12 });

    const completed = await db.syncQueue.get(item.id);
    expect(completed?.status).toBe(SyncStatus.COMPLETED);
    expect(completed?.completedAt).toBeTruthy();

    const task = await db.tasks.get('task-1');
    expect(task?.lastSyncedCount).toBe(12);
  });

  it('completes a non-counting push (null advance) without touching tasks', async () => {
    const item = makeQueueItem({ entityType: 'boards', entityId: 'board-1' });
    await db.syncQueue.add(item);

    await completePushedItem(item.id, null);

    const completed = await db.syncQueue.get(item.id);
    expect(completed?.status).toBe(SyncStatus.COMPLETED);
  });
});

describe('completePushedItem — degradation path (atomic rollback)', () => {
  it('rolls back BOTH the completion and the advance when the count write fails', async () => {
    const item = makeQueueItem();
    await db.syncQueue.add(item);
    await db.tasks.add(makeCountingTask({ currentCount: 12, lastSyncedCount: 3 }));

    // Force a mid-transaction failure via the test-only seam: the throw fires
    // after the queue-completion write but before the count advance, so a
    // non-atomic implementation would leave the item COMPLETED with a stale
    // lastSyncedCount — the exact silent degradation D2 fixes.
    await expect(
      completePushedItem(
        item.id,
        { taskId: 'task-1', pushedCount: 12 },
        { beforeCountAdvance: () => { throw new Error('synthetic mid-transaction failure'); } },
      ),
    ).rejects.toThrow('synthetic mid-transaction failure');

    // Neither write survived: the item is still IN_PROGRESS and the ancestor
    // is unchanged. The push loop will mark it FAILED and retry.
    const afterFail = await db.syncQueue.get(item.id);
    expect(afterFail?.status).toBe(SyncStatus.IN_PROGRESS);
    expect(afterFail?.completedAt).toBeUndefined();

    const task = await db.tasks.get('task-1');
    expect(task?.lastSyncedCount).toBe(3);
  });
});

describe('completePushedItem — idempotency', () => {
  it('is harmless when applied twice (advance sets ancestor := pushed value)', async () => {
    const item = makeQueueItem();
    await db.syncQueue.add(item);
    await db.tasks.add(makeCountingTask({ currentCount: 12, lastSyncedCount: 3 }));

    await completePushedItem(item.id, { taskId: 'task-1', pushedCount: 12 });
    await completePushedItem(item.id, { taskId: 'task-1', pushedCount: 12 });

    const completed = await db.syncQueue.get(item.id);
    expect(completed?.status).toBe(SyncStatus.COMPLETED);

    const task = await db.tasks.get('task-1');
    expect(task?.lastSyncedCount).toBe(12);
  });
});
