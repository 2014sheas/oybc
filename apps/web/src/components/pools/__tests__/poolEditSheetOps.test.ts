import { afterEach, describe, expect, it } from 'vitest';
import { db } from '../../../db/internal';
import { fetchPool } from '../../../db/operations/pools';
import { deletePoolFromSheet, savePoolFromSheet } from '../poolEditSheetOps';

/**
 * poolEditSheetOps.test.ts — op-level coverage for `PoolEditSheet`'s
 * save/create/delete seam (P2 Task 2). `savePoolFromSheet`/
 * `deletePoolFromSheet` are the exact functions the sheet's Save/Create/
 * Delete buttons call, extracted so this repo's lack of a component-render
 * harness doesn't leave the sheet's persistence branch untested.
 */

afterEach(async () => {
  await db.pools.clear();
  await db.syncQueue.clear();
});

describe('savePoolFromSheet', () => {
  it('create mode (pool undefined): mints a new pool, trimming the name', async () => {
    const created = await savePoolFromSheet('user-1', undefined, {
      name: '  Morning Kickstart  ',
      taskIds: ['t1', 't2'],
    });

    expect(created.userId).toBe('user-1');
    expect(created.name).toBe('Morning Kickstart');
    expect(created.taskIds).toEqual(['t1', 't2']);
    expect(created.version).toBe(1);

    const stored = await fetchPool(created.id);
    expect(stored).toEqual(created);
  });

  it('edit mode (pool provided): updates the existing row in place', async () => {
    const created = await savePoolFromSheet('user-1', undefined, {
      name: 'A',
      taskIds: ['t1'],
    });

    const saved = await savePoolFromSheet('user-1', created, {
      name: '  Renamed  ',
      taskIds: ['t1', 't2'],
    });

    expect(saved.id).toBe(created.id);
    expect(saved.name).toBe('Renamed');
    expect(saved.taskIds).toEqual(['t1', 't2']);
    expect(saved.version).toBe(2);
  });

  it('edit mode throws if the pool no longer exists (e.g. deleted out from under an open sheet)', async () => {
    const created = await savePoolFromSheet('user-1', undefined, { name: 'A', taskIds: [] });
    await deletePoolFromSheet(created);

    // updatePool on a soft-deleted-but-still-present row still succeeds at
    // the DB layer (soft delete doesn't remove the row) — exercise the
    // "row genuinely missing" branch by faking an id that was never created.
    const ghost = { ...created, id: 'does-not-exist' };
    await expect(savePoolFromSheet('user-1', ghost, { name: 'A', taskIds: [] })).rejects.toThrow(
      'Pool no longer exists',
    );
  });
});

describe('deletePoolFromSheet', () => {
  it('soft-deletes the pool (never hard-deletes, never cascades)', async () => {
    const created = await savePoolFromSheet('user-1', undefined, {
      name: 'A',
      taskIds: ['t1'],
    });

    await deletePoolFromSheet(created);

    const stored = await fetchPool(created.id);
    expect(stored?.isDeleted).toBe(true);
    expect(stored?.taskIds).toEqual(['t1']); // taskIds untouched — detachment is derived, not cascaded
  });
});
