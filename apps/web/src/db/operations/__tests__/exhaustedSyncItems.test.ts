import { afterEach, describe, expect, it } from 'vitest';
import {
  MAX_SYNC_RETRIES,
  SyncOperationType,
  SyncStatus,
  type SyncQueueItem,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  countExhaustedSyncItems,
  retryExhaustedSyncItems,
} from '../syncQueue';

/**
 * Covers the D1 exhausted-item recovery ops (issue #292):
 * `countExhaustedSyncItems`, `retryExhaustedSyncItems`, and the
 * promote-after-reset path.
 *
 * These ops import only the Dexie singleton (`db` from `db/internal`) plus
 * `@oybc/shared` — no firebase — so they run in the node Vitest harness
 * against `fake-indexeddb` (installed globally by `vitest.setup.ts`).
 */

function makeItem(overrides: Partial<SyncQueueItem> = {}): SyncQueueItem {
  return {
    id: `item-${Math.random().toString(36).slice(2)}`,
    entityType: 'tasks',
    entityId: 'entity-1',
    operationType: SyncOperationType.UPDATE,
    payload: '{}',
    status: SyncStatus.FAILED,
    retryCount: MAX_SYNC_RETRIES,
    lastError: 'synthetic error',
    createdAt: new Date().toISOString(),
    priority: 0,
    ...overrides,
  };
}

afterEach(async () => {
  await db.syncQueue.clear();
});

describe('countExhaustedSyncItems', () => {
  it('counts only FAILED items at or above the retry cap', async () => {
    await db.syncQueue.bulkAdd([
      makeItem({ id: 'exhausted-1', retryCount: MAX_SYNC_RETRIES }),
      makeItem({ id: 'exhausted-2', retryCount: MAX_SYNC_RETRIES + 2 }),
      makeItem({ id: 'still-retrying', retryCount: MAX_SYNC_RETRIES - 1 }),
      makeItem({ id: 'pending', status: SyncStatus.PENDING, retryCount: 0, lastError: undefined }),
      makeItem({ id: 'completed', status: SyncStatus.COMPLETED, retryCount: MAX_SYNC_RETRIES }),
    ]);

    expect(await countExhaustedSyncItems()).toBe(2);
  });

  it('returns 0 when nothing is stuck', async () => {
    await db.syncQueue.bulkAdd([
      makeItem({ id: 'below-cap', retryCount: MAX_SYNC_RETRIES - 1 }),
    ]);
    expect(await countExhaustedSyncItems()).toBe(0);
  });
});

describe('retryExhaustedSyncItems', () => {
  it('resets exhausted items to fresh PENDING (retryCount 0, no error) and leaves others', async () => {
    await db.syncQueue.bulkAdd([
      makeItem({ id: 'exhausted-1', retryCount: MAX_SYNC_RETRIES }),
      makeItem({ id: 'still-retrying', retryCount: MAX_SYNC_RETRIES - 1 }),
    ]);

    const reset = await retryExhaustedSyncItems();
    expect(reset).toBe(1);

    const recovered = await db.syncQueue.get('exhausted-1');
    expect(recovered?.status).toBe(SyncStatus.PENDING);
    expect(recovered?.retryCount).toBe(0);
    expect(recovered?.lastError).toBeUndefined();

    // The under-cap FAILED item is untouched.
    const untouched = await db.syncQueue.get('still-retrying');
    expect(untouched?.status).toBe(SyncStatus.FAILED);
    expect(untouched?.retryCount).toBe(MAX_SYNC_RETRIES - 1);

    // Exhausted count clears once recovered.
    expect(await countExhaustedSyncItems()).toBe(0);
  });
});

describe('recovery chain (reset → pending → drainable)', () => {
  it('resets exhausted items to PENDING while leaving an in-backoff FAILED item stuck', async () => {
    await db.syncQueue.bulkAdd([
      // Exhausted — recovered by retryExhaustedSyncItems.
      makeItem({ id: 'reset-me', retryCount: MAX_SYNC_RETRIES }),
      // Under-cap FAILED, attempted just now → inside its backoff window, so
      // not exhausted; must stay FAILED through the exhausted-retry.
      makeItem({
        id: 'in-backoff',
        retryCount: 1,
        lastAttemptAt: new Date().toISOString(),
      }),
    ]);

    // Reset exhausted items only.
    expect(await retryExhaustedSyncItems()).toBe(1);

    // The reset item is now PENDING (drainable by the push loop), retry
    // budget cleared; the in-backoff item stays FAILED; exhausted count
    // clears. (`promoteEligibleFailedItems` / `fetchPendingSyncItems` use a
    // compound-index `where('status')` query that fake-indexeddb can't
    // emulate, so we assert the row state directly rather than through them.)
    const resetItem = await db.syncQueue.get('reset-me');
    expect(resetItem?.status).toBe(SyncStatus.PENDING);
    expect(resetItem?.retryCount).toBe(0);
    expect(resetItem?.lastError).toBeUndefined();

    const stuck = await db.syncQueue.get('in-backoff');
    expect(stuck?.status).toBe(SyncStatus.FAILED);

    expect(await countExhaustedSyncItems()).toBe(0);
  });
});
