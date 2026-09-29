import { afterEach, describe, expect, it } from 'vitest';
import { CenterSquareType, SyncOperationType, TaskType, Timeframe, type Pool, type Task } from '@oybc/shared';
import { db } from '../../internal';
import {
  createCoreBoardDefault,
  fetchCoreBoardDefault,
  fetchCoreBoardDefaults,
  softDeleteCoreBoardDefault,
  updateCoreBoardDefault,
  upsertCoreBoardDefault,
} from '../coreBoardDefaults';
import { applyCoreBoardDefaultPrefill } from '../../../pages/createHub/poolPullLogic';

/**
 * CoreBoardDefault CRUD (Task Pools + Recurring Boards Rework, P1).
 * Modeled directly on `defaultPools.ts`'s create/fetch/upsert/soft-delete
 * shape — it replaces `DefaultPool` one-for-one at the persistence layer.
 */

afterEach(async () => {
  await db.coreBoardDefaults.clear();
  await db.syncQueue.clear();
});

describe('coreBoardDefaults CRUD', () => {
  it('createCoreBoardDefault inserts a row and enqueues a sync CREATE', async () => {
    const row = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.DAILY,
      corePoolIds: ['pool-1'],
      coreDefaultTaskIds: [],
    });

    expect(row.timeframe).toBe(Timeframe.DAILY);
    expect(row.corePoolIds).toEqual(['pool-1']);
    expect(row.coreDefaultTaskIds).toEqual([]);
    expect(row.version).toBe(1);

    const queue = await db.syncQueue.toArray();
    expect(queue).toHaveLength(1);
    expect(queue[0].entityType).toBe('coreBoardDefaults');
    expect(queue[0].operationType).toBe(SyncOperationType.CREATE);
  });

  it('fetchCoreBoardDefaults returns only non-deleted rows for the given user', async () => {
    const daily = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.DAILY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
    });
    await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.WEEKLY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
    });
    await createCoreBoardDefault('user-2', {
      timeframe: Timeframe.DAILY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
    });
    await softDeleteCoreBoardDefault(daily.id);

    const rows = await fetchCoreBoardDefaults('user-1');
    expect(rows.map((r) => r.timeframe)).toEqual([Timeframe.WEEKLY]);
  });

  it('fetchCoreBoardDefault returns the (at most one) non-deleted row for (userId, timeframe)', async () => {
    await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.MONTHLY,
      corePoolIds: ['pool-x'],
      coreDefaultTaskIds: [],
    });

    const found = await fetchCoreBoardDefault('user-1', Timeframe.MONTHLY);
    expect(found?.corePoolIds).toEqual(['pool-x']);
    expect(await fetchCoreBoardDefault('user-1', Timeframe.YEARLY)).toBeUndefined();
  });

  it('updateCoreBoardDefault bumps version + updatedAt', async () => {
    const row = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.DAILY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
    });

    const updated = await updateCoreBoardDefault(row.id, {
      corePoolIds: ['pool-1'],
      coreDefaultTaskIds: ['task-1'],
    });

    expect(updated?.corePoolIds).toEqual(['pool-1']);
    expect(updated?.coreDefaultTaskIds).toEqual(['task-1']);
    expect(updated?.version).toBe(2);
  });

  it('upsertCoreBoardDefault creates when absent, updates when present, enforcing per-(user,timeframe) uniqueness', async () => {
    const created = await upsertCoreBoardDefault('user-1', Timeframe.DAILY, {
      corePoolIds: ['pool-1'],
    });
    expect(created.version).toBe(1);

    const updated = await upsertCoreBoardDefault('user-1', Timeframe.DAILY, {
      corePoolIds: ['pool-1', 'pool-2'],
    });
    expect(updated.id).toBe(created.id); // same row, not a duplicate
    expect(updated.corePoolIds).toEqual(['pool-1', 'pool-2']);
    expect(updated.version).toBe(2);

    const all = await fetchCoreBoardDefaults('user-1');
    expect(all).toHaveLength(1);
  });

  it('upsertCoreBoardDefault with only corePoolIds leaves an existing coreDefaultTaskIds untouched (P5 checkbox write path)', async () => {
    const created = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.DAILY,
      corePoolIds: [],
      coreDefaultTaskIds: ['task-1', 'task-2'],
    });

    const updated = await upsertCoreBoardDefault('user-1', Timeframe.DAILY, {
      corePoolIds: ['pool-1'],
    });

    expect(updated.id).toBe(created.id);
    expect(updated.corePoolIds).toEqual(['pool-1']);
    // The P7-authored-only field must survive a corePoolIds-only write.
    expect(updated.coreDefaultTaskIds).toEqual(['task-1', 'task-2']);
  });

  it('softDeleteCoreBoardDefault sets isDeleted/deletedAt and bumps version', async () => {
    const row = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.DAILY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
    });

    await softDeleteCoreBoardDefault(row.id);

    const stored = await db.coreBoardDefaults.get(row.id);
    expect(stored?.isDeleted).toBe(true);
    expect(stored?.deletedAt).toBeTruthy();
    expect(stored?.version).toBe(2);
  });
});

/**
 * P7 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 9 "defaults sheet") — `CoreDefaultsSheet` is the FIRST
 * writer of `coreDefaultTaskIds` (P1 shipped the field synced-but-unwritten;
 * P5's core-setup prefill already reads it). This round-trips the sheet's
 * exact save call — both fields together in one `upsertCoreBoardDefault`
 * call — through to the P5 prefill function that resolves them back out,
 * confirming the two features actually connect end to end.
 */
describe('P7 defaults-sheet round trip', () => {
  function buildTask(id: string, overrides: Partial<Task> = {}): Task {
    return {
      id,
      userId: 'user-1',
      title: `Task ${id}`,
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: '2026-08-01T00:00:00.000Z',
      updatedAt: '2026-08-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
      ...overrides,
    };
  }

  function buildPool(id: string, taskIds: string[]): Pool {
    return {
      id,
      userId: 'user-1',
      name: `Pool ${id}`,
      taskIds,
      createdAt: '2026-08-01T00:00:00.000Z',
      updatedAt: '2026-08-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    };
  }

  it('upsertCoreBoardDefault saves corePoolIds and coreDefaultTaskIds together in one call', async () => {
    const saved = await upsertCoreBoardDefault('user-1', Timeframe.DAILY, {
      corePoolIds: ['pool-1'],
      coreDefaultTaskIds: ['task-manual'],
    });
    expect(saved.corePoolIds).toEqual(['pool-1']);
    expect(saved.coreDefaultTaskIds).toEqual(['task-manual']);

    const refetched = await fetchCoreBoardDefault('user-1', Timeframe.DAILY);
    expect(refetched?.corePoolIds).toEqual(['pool-1']);
    expect(refetched?.coreDefaultTaskIds).toEqual(['task-manual']);
  });

  it('the freshly-authored coreDefaultTaskIds is picked up by the P5 core-setup prefill', async () => {
    const poolTask = buildTask('pool-task');
    const manualTask = buildTask('task-manual');
    const pool = buildPool('pool-1', ['pool-task']);
    const poolsById: Record<string, Pool> = { [pool.id]: pool };
    const tasksById: Record<string, Task> = {
      [poolTask.id]: poolTask,
      [manualTask.id]: manualTask,
    };

    // Before P7, coreDefaultTaskIds is synced-but-unwritten — prefill only
    // ever resolves pool-sourced tasks.
    const beforeSave = await fetchCoreBoardDefault('user-1', Timeframe.WEEKLY);
    expect(beforeSave).toBeUndefined();

    await upsertCoreBoardDefault('user-1', Timeframe.WEEKLY, {
      corePoolIds: ['pool-1'],
      coreDefaultTaskIds: ['task-manual'],
    });

    const saved = await fetchCoreBoardDefault('user-1', Timeframe.WEEKLY);
    expect(saved).toBeDefined();
    const prefill = applyCoreBoardDefaultPrefill(
      saved!.corePoolIds,
      saved!.coreDefaultTaskIds,
      poolsById,
      tasksById,
    );
    expect(prefill.selectedTaskIds).toEqual(new Set(['pool-task', 'task-manual']));
    expect(prefill.pulledPoolIds).toEqual(['pool-1']);
  });
});

/**
 * Per-timeframe size + centre (docs/POOLS_RECURRING.md §Per-timeframe size +
 * centre, 2026-09-29). Both fields are optional overrides; `null` on update
 * CLEARS back to inherit and is stored as ABSENT (never `null`) so the push
 * path's clearable-field delete fires and the Zod row schema keeps parsing.
 */
describe('coreBoardDefaults — defaultBoardSize / defaultCenterType', () => {
  afterEach(async () => {
    await db.coreBoardDefaults.clear();
    await db.syncQueue.clear();
  });

  it('create stores the overrides when given, and leaves them ABSENT when omitted or null', async () => {
    const withBoth = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.DAILY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
      defaultBoardSize: 3,
      defaultCenterType: CenterSquareType.NONE,
    });
    expect(withBoth.defaultBoardSize).toBe(3);
    expect(withBoth.defaultCenterType).toBe(CenterSquareType.NONE);

    const omitted = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.WEEKLY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
    });
    expect(omitted).not.toHaveProperty('defaultBoardSize');
    expect(omitted).not.toHaveProperty('defaultCenterType');

    const nulled = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.MONTHLY,
      corePoolIds: [],
      coreDefaultTaskIds: [],
      defaultBoardSize: null,
      defaultCenterType: null,
    });
    expect(nulled).not.toHaveProperty('defaultBoardSize');
    expect(nulled).not.toHaveProperty('defaultCenterType');
    const stored = await db.coreBoardDefaults.get(nulled.id);
    expect(stored).not.toHaveProperty('defaultBoardSize');
    expect(stored).not.toHaveProperty('defaultCenterType');
  });

  it('update: omitted keeps, a value sets, null clears to ABSENT — each bumping version + enqueueing', async () => {
    const row = await createCoreBoardDefault('user-1', {
      timeframe: Timeframe.DAILY,
      corePoolIds: ['pool-1'],
      coreDefaultTaskIds: [],
    });

    // set both
    const set = await updateCoreBoardDefault(row.id, {
      defaultBoardSize: 4,
      defaultCenterType: CenterSquareType.FREE,
    });
    expect(set?.defaultBoardSize).toBe(4);
    expect(set?.defaultCenterType).toBe(CenterSquareType.FREE);
    expect(set?.corePoolIds).toEqual(['pool-1']); // untouched
    expect(set?.version).toBe(2);

    // omitted = keep (a pools-only edit must not stomp the overrides)
    const kept = await updateCoreBoardDefault(row.id, { corePoolIds: ['pool-2'] });
    expect(kept?.defaultBoardSize).toBe(4);
    expect(kept?.defaultCenterType).toBe(CenterSquareType.FREE);
    expect(kept?.corePoolIds).toEqual(['pool-2']);
    expect(kept?.version).toBe(3);

    // null = clear ONE, keep the other
    const clearedSize = await updateCoreBoardDefault(row.id, { defaultBoardSize: null });
    expect(clearedSize).not.toHaveProperty('defaultBoardSize');
    expect(clearedSize?.defaultCenterType).toBe(CenterSquareType.FREE);
    expect(clearedSize?.version).toBe(4);

    const clearedCentre = await updateCoreBoardDefault(row.id, { defaultCenterType: null });
    expect(clearedCentre).not.toHaveProperty('defaultBoardSize');
    expect(clearedCentre).not.toHaveProperty('defaultCenterType');
    expect(clearedCentre?.version).toBe(5);

    // The stored row (not just the returned one) is null-free / key-free.
    const stored = await db.coreBoardDefaults.get(row.id);
    expect(stored).not.toHaveProperty('defaultBoardSize');
    expect(stored).not.toHaveProperty('defaultCenterType');

    // Every update enqueued (D3 coalesces onto the pending create row).
    const queued = await db.syncQueue.filter((q) => q.entityId === row.id).toArray();
    expect(queued.length).toBeGreaterThanOrEqual(1);
    const last = queued[queued.length - 1];
    expect(last.payload).not.toHaveProperty('defaultBoardSize');
    expect(last.payload).not.toHaveProperty('defaultCenterType');
  });

  it('upsert round-trip: set on create, keep on a pools-only save, clear via null', async () => {
    const created = await upsertCoreBoardDefault('user-1', Timeframe.YEARLY, {
      corePoolIds: [],
      coreDefaultTaskIds: [],
      defaultBoardSize: 5,
      defaultCenterType: CenterSquareType.NONE,
    });
    expect(created.version).toBe(1);
    expect(created.defaultBoardSize).toBe(5);
    expect(created.defaultCenterType).toBe(CenterSquareType.NONE);

    const poolsOnly = await upsertCoreBoardDefault('user-1', Timeframe.YEARLY, {
      corePoolIds: ['pool-9'],
    });
    expect(poolsOnly.id).toBe(created.id);
    expect(poolsOnly.defaultBoardSize).toBe(5);
    expect(poolsOnly.defaultCenterType).toBe(CenterSquareType.NONE);

    const cleared = await upsertCoreBoardDefault('user-1', Timeframe.YEARLY, {
      defaultBoardSize: null,
      defaultCenterType: null,
    });
    expect(cleared.id).toBe(created.id);
    expect(cleared).not.toHaveProperty('defaultBoardSize');
    expect(cleared).not.toHaveProperty('defaultCenterType');
    expect(cleared.corePoolIds).toEqual(['pool-9']);
    expect(await fetchCoreBoardDefaults('user-1')).toHaveLength(1);
  });
});
