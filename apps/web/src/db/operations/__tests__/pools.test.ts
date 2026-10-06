import { afterEach, describe, expect, it } from 'vitest';
import { SyncOperationType } from '@oybc/shared';
import { db } from '../../internal';
import {
  createPool,
  fetchPool,
  fetchPools,
  fetchPoolsByIds,
  softDeletePool,
  updatePool,
} from '../pools';

/**
 * Pool CRUD (Task Pools + Recurring Boards Rework, P1). Modeled on
 * `defaultPools.ts`'s test coverage pattern (there is no dedicated
 * defaultPools test file to mirror line-for-line, so this follows the
 * repo's general CRUD-op test shape — create/fetch/update/soft-delete +
 * a sync-queue enqueue assertion per write).
 */

afterEach(async () => {
  await db.pools.clear();
  await db.syncQueue.clear();
});

describe('pools CRUD', () => {
  it('createPool inserts a row and enqueues a sync CREATE', async () => {
    const pool = await createPool('user-1', { name: '  Morning Kickstart  ', taskIds: ['t1', 't2'] });

    expect(pool.name).toBe('Morning Kickstart'); // trimmed
    expect(pool.taskIds).toEqual(['t1', 't2']);
    expect(pool.version).toBe(1);
    expect(pool.isDeleted).toBe(false);

    const stored = await db.pools.get(pool.id);
    expect(stored).toEqual(pool);

    const queue = await db.syncQueue.toArray();
    expect(queue).toHaveLength(1);
    expect(queue[0].entityType).toBe('pools');
    expect(queue[0].operationType).toBe(SyncOperationType.CREATE);
  });

  it('fetchPools returns only non-deleted pools for the given user', async () => {
    const a = await createPool('user-1', { name: 'A', taskIds: [] });
    await createPool('user-1', { name: 'B', taskIds: [] });
    await createPool('user-2', { name: 'Other user', taskIds: [] });
    await softDeletePool(a.id);

    const pools = await fetchPools('user-1');
    expect(pools.map((p) => p.name)).toEqual(['B']);
  });

  it('fetchPool returns a single row by id regardless of isDeleted', async () => {
    const pool = await createPool('user-1', { name: 'A', taskIds: [] });
    await softDeletePool(pool.id);

    const found = await fetchPool(pool.id);
    expect(found?.isDeleted).toBe(true);
  });

  it('fetchPoolsByIds batches a lookup and returns [] for an empty input', async () => {
    const a = await createPool('user-1', { name: 'A', taskIds: [] });
    const b = await createPool('user-1', { name: 'B', taskIds: [] });

    expect(await fetchPoolsByIds([])).toEqual([]);
    const found = await fetchPoolsByIds([a.id, b.id, 'missing-id']);
    expect(found.map((p) => p.id).sort()).toEqual([a.id, b.id].sort());
  });

  it('updatePool bumps version + updatedAt and coalesces the still-unpushed sync row (D3) to carry the latest snapshot', async () => {
    const pool = await createPool('user-1', { name: 'A', taskIds: ['t1'] });

    const updated = await updatePool(pool.id, { name: 'Renamed', taskIds: ['t1', 't2'] });

    expect(updated?.name).toBe('Renamed');
    expect(updated?.taskIds).toEqual(['t1', 't2']);
    expect(updated?.version).toBe(2);

    // D3 (issue #296) coalescing: the CREATE row for this entity was never
    // pushed, so the UPDATE replaces it in place rather than appending a
    // second row — the queue still shows one PENDING row for this pool,
    // now carrying the latest ('Renamed') snapshot (see
    // `coalesceSyncOperation` in `syncQueue.ts` for the full precedence
    // table; `coalesceSyncQueue.test.ts` covers the coalescer itself).
    const queue = await db.syncQueue
      .filter((q) => q.entityType === 'pools' && q.entityId === pool.id)
      .toArray();
    expect(queue).toHaveLength(1);
    expect(queue[0].operationType).toBe(SyncOperationType.CREATE);
    expect(JSON.parse(queue[0].payload).name).toBe('Renamed');
  });

  // Pool-level default dice (2026-10-06, docs/BOARD_SOURCES.md §Member rules
  // → Pool-level defaults). The map is ALWAYS written (`{}` when empty) and
  // only levels 1 | 2 are stored — a 0 is pruned exactly as `withMemberRule`
  // prunes a `vary: 0` off a source rule.
  it('createPool always writes memberVary — {} when absent, pruned of 0s otherwise', async () => {
    const bare = await createPool('user-1', { name: 'Bare', taskIds: ['t1'] });
    expect(bare.memberVary).toEqual({});
    expect((await db.pools.get(bare.id))?.memberVary).toEqual({});

    const dice = await createPool('user-1', {
      name: 'Dice',
      taskIds: ['t1', 't2', 't3'],
      memberVary: { t1: 0, t2: 1, t3: 2 },
    });
    expect(dice.memberVary).toEqual({ t2: 1, t3: 2 });
    expect((await db.pools.get(dice.id))?.memberVary).toEqual({ t2: 1, t3: 2 });
    const queued = JSON.parse(
      (await db.syncQueue.filter((q) => q.entityId === dice.id).toArray())[0].payload,
    );
    expect(queued.memberVary).toEqual({ t2: 1, t3: 2 });
  });

  it('updatePool replaces memberVary when given (pruned; a full clear stores {}) and leaves it alone when absent', async () => {
    const pool = await createPool('user-1', { name: 'A', taskIds: ['t1', 't2'], memberVary: { t1: 2 } });

    const renamed = await updatePool(pool.id, { name: 'Renamed' });
    expect(renamed?.memberVary).toEqual({ t1: 2 }); // untouched

    const changed = await updatePool(pool.id, { memberVary: { t1: 0, t2: 1 } });
    expect(changed?.memberVary).toEqual({ t2: 1 });

    const cleared = await updatePool(pool.id, { memberVary: {} });
    expect(cleared?.memberVary).toEqual({});
    expect('memberVary' in (await db.pools.get(pool.id))!).toBe(true);
  });

  it('updatePool returns undefined for a missing id (no throw)', async () => {
    expect(await updatePool('does-not-exist', { name: 'X' })).toBeUndefined();
  });

  it('softDeletePool sets isDeleted/deletedAt, bumps version, and coalesces the still-unpushed CREATE+DELETE to a drop', async () => {
    const pool = await createPool('user-1', { name: 'A', taskIds: [] });

    await softDeletePool(pool.id);

    const stored = await db.pools.get(pool.id);
    expect(stored?.isDeleted).toBe(true);
    expect(stored?.deletedAt).toBeTruthy();
    expect(stored?.version).toBe(2);

    // D3 coalescing: an unpushed CREATE followed by a DELETE nets to
    // nothing (the client-generated id was never seen by any peer), so the
    // queue row is DROPPED rather than replaced with a DELETE — see
    // `coalesceSyncOperation`'s "CREATE + DELETE (never attempted) → drop"
    // rule.
    const queue = await db.syncQueue
      .filter((q) => q.entityType === 'pools' && q.entityId === pool.id)
      .toArray();
    expect(queue).toHaveLength(0);
  });
});
