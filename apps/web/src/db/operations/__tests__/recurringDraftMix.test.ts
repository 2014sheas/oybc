import { afterEach, describe, expect, it } from 'vitest';
import { TaskType, type Pool, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { encodeRecurringDraftMix } from '../../recurringDraftMix';
import { resolveRecurringDraftMixTaskIds } from '../recurringDraftMix';

const NOW = '2026-08-01T00:00:00.000Z';

function makeTask(id: string, overrides: Partial<Task> = {}): Task {
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
    ...overrides,
  };
}

function makePool(id: string, taskIds: string[], overrides: Partial<Pool> = {}): Pool {
  return {
    id,
    userId: 'user-1',
    name: `Pool ${id}`,
    taskIds,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

afterEach(async () => {
  await db.tasks.clear();
  await db.pools.clear();
});

describe('resolveRecurringDraftMixTaskIds', () => {
  it('resolves the union of pool supply plus manual tasks, minus removals', async () => {
    const poolTasks = [makeTask('p1'), makeTask('p2'), makeTask('p3')];
    await db.tasks.bulkAdd(poolTasks);
    await db.tasks.add(makeTask('manual-1'));
    await db.pools.add(makePool('pool-1', ['p1', 'p2', 'p3']));

    const mixJson = encodeRecurringDraftMix({
      poolIds: ['pool-1'],
      manualTaskIds: ['manual-1'],
      removedTaskIds: ['p2'],
    });

    const resolved = await resolveRecurringDraftMixTaskIds(mixJson);
    expect(new Set(resolved)).toEqual(new Set(['p1', 'p3', 'manual-1']));
  });

  it('skips a soft-deleted pool\'s supply, but passes a manual id through verbatim (resolveMix\'s "caller-curated manual layer" contract)', async () => {
    await db.tasks.bulkAdd([
      makeTask('a1'),
      makeTask('a2'),
      makeTask('deleted-manual', { isDeleted: true }),
    ]);
    await db.pools.add(makePool('deleted-pool', ['a1'], { isDeleted: true }));
    await db.pools.add(makePool('live-pool', ['a2']));

    const mixJson = encodeRecurringDraftMix({
      poolIds: ['deleted-pool', 'live-pool'],
      manualTaskIds: ['deleted-manual'],
      removedTaskIds: [],
    });

    const resolved = await resolveRecurringDraftMixTaskIds(mixJson);
    // `deleted-pool`'s supply ('a1') never enters the union; `live-pool`'s
    // ('a2') does. The manual id passes through regardless of the
    // referenced task's deletion state — `resolveMix` never filters
    // `manualTaskIds` (that's the caller's job; the wizard/roster UI only
    // ever lets a user pick a live task in the first place).
    expect(new Set(resolved)).toEqual(new Set(['a2', 'deleted-manual']));
  });

  it('returns [] for a missing/malformed mix without throwing', async () => {
    expect(await resolveRecurringDraftMixTaskIds(undefined)).toEqual([]);
    expect(await resolveRecurringDraftMixTaskIds('not json')).toEqual([]);
  });

  it('reflects an overfilled pool (more tasks than any grid needs) — overfill is preserved, never truncated', async () => {
    const ids = Array.from({ length: 12 }, (_, i) => `t${i}`);
    await db.tasks.bulkAdd(ids.map((id) => makeTask(id)));
    await db.pools.add(makePool('big-pool', ids));

    const mixJson = encodeRecurringDraftMix({
      poolIds: ['big-pool'],
      manualTaskIds: [],
      removedTaskIds: [],
    });

    const resolved = await resolveRecurringDraftMixTaskIds(mixJson);
    expect(resolved).toHaveLength(12);
  });
});
