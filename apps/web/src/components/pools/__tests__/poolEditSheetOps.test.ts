import { afterEach, describe, expect, it, vi } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { emptyPatch, type TaskEditPatch } from '../../../db/taskEditPatch';
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
  vi.restoreAllMocks();
  await db.pools.clear();
  await db.tasks.clear();
  await db.syncQueue.clear();
});

const NOW = '2026-10-05T00:00:00.000Z';
function seedable(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  };
}
function titlePatch(title: string): Map<string, TaskEditPatch> {
  return new Map([['t1', emptyPatch(title)]]);
}

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

  // I-1 — the 120-char PoolSchema.name bound. The sheet's `maxLength`
  // attribute stops most typing, but paste/IME input can still bypass a
  // DOM attribute, so the save path re-checks — a name that saves past
  // this fails Zod on the next pull (same class as P1's minted-name
  // clamp, a different — user-typed — entry point).
  it('accepts a name at exactly the 120-char bound', async () => {
    const name = 'a'.repeat(120);
    const created = await savePoolFromSheet('user-1', undefined, { name, taskIds: [] });
    expect(created.name).toBe(name);
    expect(created.name.length).toBe(120);
  });

  it('rejects a 121-char name before it ever reaches the DB layer', async () => {
    const name = 'a'.repeat(121);
    await expect(
      savePoolFromSheet('user-1', undefined, { name, taskIds: [] }),
    ).rejects.toThrow('Pool name must be 120 characters or fewer.');

    // Never wrote a row — the check runs before create/update.
    const all = await db.pools.toArray();
    expect(all).toHaveLength(0);
  });

  it('rejects a 121-char name in edit mode too, without mutating the existing row', async () => {
    const created = await savePoolFromSheet('user-1', undefined, { name: 'A', taskIds: [] });
    const tooLong = 'b'.repeat(121);
    await expect(
      savePoolFromSheet('user-1', created, { name: tooLong, taskIds: [] }),
    ).rejects.toThrow('Pool name must be 120 characters or fewer.');

    const stored = await fetchPool(created.id);
    expect(stored?.name).toBe('A');
    expect(stored?.version).toBe(1);
  });

  it('the 120-char check runs against the TRIMMED name (surrounding whitespace does not count)', async () => {
    const name = `  ${'c'.repeat(120)}  `;
    const created = await savePoolFromSheet('user-1', undefined, { name, taskIds: [] });
    expect(created.name).toBe('c'.repeat(120));
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

describe('savePoolFromSheet — staged inline edits ride the same transaction', () => {
  it('create mode: applies the staged edit AND writes the membership', async () => {
    await db.tasks.add(seedable('t1', { title: 'Old title' }));

    const pool = await savePoolFromSheet('user-1', undefined, {
      name: 'P',
      taskIds: ['t1'],
      stagedEdits: titlePatch('New title'),
    });

    expect((await db.tasks.get('t1'))?.title).toBe('New title');
    expect((await db.tasks.get('t1'))?.version).toBe(2);
    expect((await fetchPool(pool.id))?.taskIds).toEqual(['t1']);
    const queued = (await db.syncQueue.toArray()).map((r) => r.entityType).sort();
    expect(queued).toEqual(['pools', 'tasks']);
  });

  it('edit mode: applies the staged edit and updates the membership', async () => {
    await db.tasks.add(seedable('t1', { title: 'Old title' }));
    const created = await savePoolFromSheet('user-1', undefined, { name: 'P', taskIds: [] });

    const updated = await savePoolFromSheet('user-1', created, {
      name: 'P2',
      taskIds: ['t1'],
      stagedEdits: titlePatch('Renamed'),
    });

    expect(updated.name).toBe('P2');
    expect((await db.tasks.get('t1'))?.title).toBe('Renamed');
  });

  it('derives a Counting task blank title from action / goal / unit', async () => {
    await db.tasks.add(
      seedable('t1', { type: TaskType.COUNTING, title: 'Run 5 km', action: 'Run', unit: 'km', maxCount: 5 }),
    );
    const patch: TaskEditPatch = { ...emptyPatch(''), action: 'Walk', goal: '8', unit: 'km' };

    await savePoolFromSheet('user-1', undefined, {
      name: 'P',
      taskIds: ['t1'],
      stagedEdits: new Map([['t1', patch]]),
    });

    const stored = await db.tasks.get('t1');
    expect(stored?.maxCount).toBe(8);
    expect(stored?.title).toBe('Walk 8 km');
  });

  it('a failing staged edit rolls back — no pool row is written', async () => {
    await db.tasks.add(seedable('t1', { title: 'Old title' }));
    vi.spyOn(db.tasks, 'update').mockRejectedValueOnce(new Error('boom'));

    await expect(
      savePoolFromSheet('user-1', undefined, {
        name: 'P',
        taskIds: ['t1'],
        stagedEdits: titlePatch('New title'),
      }),
    ).rejects.toThrow('boom');

    expect(await db.pools.count()).toBe(0);
    expect((await db.tasks.get('t1'))?.title).toBe('Old title');
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('a failing membership write rolls the staged edit back', async () => {
    await db.tasks.add(seedable('t1', { title: 'Old title' }));
    const ghost = { ...(await savePoolFromSheet('user-1', undefined, { name: 'G', taskIds: [] })), id: 'gone' };
    await db.syncQueue.clear();

    await expect(
      savePoolFromSheet('user-1', ghost, {
        name: 'P',
        taskIds: ['t1'],
        stagedEdits: titlePatch('New title'),
      }),
    ).rejects.toThrow('Pool no longer exists');

    expect((await db.tasks.get('t1'))?.title).toBe('Old title');
    expect((await db.tasks.get('t1'))?.version).toBe(1);
    expect(await db.syncQueue.count()).toBe(0);
  });
});

describe('savePoolFromSheet - memberVary (pool-level default dice)', () => {
  it('create mode stores the editor map', async () => {
    const created = await savePoolFromSheet('user-1', undefined, {
      name: 'P',
      taskIds: ['t1'],
      memberVary: { t1: 2 },
    });
    expect(created.memberVary).toEqual({ t1: 2 });
    expect((await fetchPool(created.id))?.memberVary).toEqual({ t1: 2 });
  });

  it('edit mode with the editor map replaces the stored dice (0 pruned)', async () => {
    const created = await savePoolFromSheet('user-1', undefined, {
      name: 'P',
      taskIds: ['t1', 't2'],
      memberVary: { t1: 2, t2: 1 },
    });
    const saved = await savePoolFromSheet('user-1', created, {
      name: 'P',
      taskIds: ['t1', 't2'],
      memberVary: { t1: 1 },
    });
    expect(saved.memberVary).toEqual({ t1: 1 });
    const cleared = await savePoolFromSheet('user-1', saved, {
      name: 'P',
      taskIds: ['t1', 't2'],
      memberVary: {},
    });
    expect(cleared.memberVary).toEqual({});
  });

  it('edit mode that passes the unchanged map does not wipe the stored dice', async () => {
    const created = await savePoolFromSheet('user-1', undefined, {
      name: 'P',
      taskIds: ['t1'],
      memberVary: { t1: 2 },
    });
    const saved = await savePoolFromSheet('user-1', created, {
      name: 'Renamed',
      taskIds: ['t1'],
      memberVary: created.memberVary,
    });
    expect(saved.memberVary).toEqual({ t1: 2 });
  });
});
