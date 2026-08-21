import { afterEach, describe, expect, it } from 'vitest';
import { SyncOperationType, Timeframe } from '@oybc/shared';
import { db } from '../../internal';
import {
  createCoreBoardDefault,
  fetchCoreBoardDefault,
  fetchCoreBoardDefaults,
  softDeleteCoreBoardDefault,
  updateCoreBoardDefault,
  upsertCoreBoardDefault,
} from '../coreBoardDefaults';

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
