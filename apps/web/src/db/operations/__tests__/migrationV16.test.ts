import { afterEach, describe, expect, it } from 'vitest';
import type { Transaction } from 'dexie';
import {
  CenterSquareType,
  Timeframe,
  type DefaultPool,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import { db } from '../../internal';
import { runMigrationV16 } from '../migrationV16';

/**
 * Task Pools + Recurring Boards Rework — P1 first-launch backfill
 * (docs/POOLS_RECURRING.md §Migration). `runMigrationV16` operates on the
 * raw Dexie singleton, so it can be driven directly with a passthrough
 * transaction handle, mirroring `taskEventMigration.test.ts`'s pattern for
 * `runMigrationV13`.
 */

const NOW = '2026-07-19T00:00:00.000Z';

function seedDefaultPool(overrides: Partial<DefaultPool> & Pick<DefaultPool, 'id'>): DefaultPool {
  return {
    userId: 'user-1',
    timeframe: Timeframe.DAILY,
    taskIds: ['task-a', 'task-b'],
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function seedTemplate(
  overrides: Partial<RecurringBoardTemplate> & Pick<RecurringBoardTemplate, 'id'>,
): RecurringBoardTemplate {
  return {
    userId: 'user-1',
    name: 'Daily Workout',
    timeframe: Timeframe.DAILY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    seedTaskIds: ['task-x', 'task-y', 'task-z'],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

afterEach(async () => {
  await db.defaultPools.clear();
  await db.recurringBoardTemplates.clear();
  await db.pools.clear();
  await db.coreBoardDefaults.clear();
  await db.syncQueue.clear();
});

describe('migrationV16 — Task Pools + Recurring Boards Rework backfill', () => {
  it('mints a Pool + CoreBoardDefault per DefaultPool row, named "<Timeframe> default", and soft-deletes the DefaultPool', async () => {
    await db.defaultPools.add(seedDefaultPool({ id: 'dp-1', timeframe: Timeframe.DAILY }));

    await runMigrationV16({} as Transaction);

    const pools = await db.pools.toArray();
    expect(pools).toHaveLength(1);
    expect(pools[0].name).toBe('Daily default');
    expect(pools[0].taskIds).toEqual(['task-a', 'task-b']);
    expect(pools[0].userId).toBe('user-1');

    const coreDefaults = await db.coreBoardDefaults.toArray();
    expect(coreDefaults).toHaveLength(1);
    expect(coreDefaults[0].timeframe).toBe(Timeframe.DAILY);
    expect(coreDefaults[0].corePoolIds).toEqual([pools[0].id]);
    expect(coreDefaults[0].coreDefaultTaskIds).toEqual([]);

    const dp = await db.defaultPools.get('dp-1');
    expect(dp?.isDeleted).toBe(true);
    expect(dp?.deletedAt).toBeTruthy();

    // Sync CREATE for the pool + coreDefault, DELETE tombstone for the
    // DefaultPool.
    const queue = await db.syncQueue.toArray();
    expect(queue.some((q) => q.entityType === 'pools' && q.entityId === pools[0].id)).toBe(true);
    expect(
      queue.some((q) => q.entityType === 'coreBoardDefaults' && q.entityId === coreDefaults[0].id),
    ).toBe(true);
    expect(queue.some((q) => q.entityType === 'defaultPools' && q.entityId === 'dp-1')).toBe(true);
  });

  it('mints a Pool per RecurringBoardTemplate, stamps poolIds/manualTaskIds/removedTaskIds, and leaves seedTaskIds verbatim', async () => {
    await db.recurringBoardTemplates.add(
      seedTemplate({ id: 'tmpl-1', name: 'Daily Workout', seedTaskIds: ['task-x', 'task-y', 'task-z'] }),
    );

    await runMigrationV16({} as Transaction);

    const pools = await db.pools.toArray();
    expect(pools).toHaveLength(1);
    expect(pools[0].name).toBe('Daily Workout pool');
    expect(pools[0].taskIds).toEqual(['task-x', 'task-y', 'task-z']);

    const template = await db.recurringBoardTemplates.get('tmpl-1');
    expect(template?.poolIds).toEqual([pools[0].id]);
    expect(template?.manualTaskIds).toEqual([]);
    expect(template?.removedTaskIds).toEqual([]);
    // seedTaskIds is left VERBATIM — the mix now resolves through poolIds,
    // never seedTaskIds, but the field itself is untouched.
    expect(template?.seedTaskIds).toEqual(['task-x', 'task-y', 'task-z']);
  });

  it('migrates a soft-deleted RecurringBoardTemplate too (unconditional per-row backfill)', async () => {
    await db.recurringBoardTemplates.add(
      seedTemplate({ id: 'tmpl-deleted', isDeleted: true, deletedAt: NOW }),
    );

    await runMigrationV16({} as Transaction);

    const template = await db.recurringBoardTemplates.get('tmpl-deleted');
    expect(template?.poolIds).toHaveLength(1);
    expect(template?.isDeleted).toBe(true);
  });

  it('is idempotent — a second run does not duplicate Pools/CoreBoardDefaults or re-touch already-migrated rows', async () => {
    await db.defaultPools.add(seedDefaultPool({ id: 'dp-1', timeframe: Timeframe.WEEKLY }));
    await db.recurringBoardTemplates.add(seedTemplate({ id: 'tmpl-1' }));

    await runMigrationV16({} as Transaction);
    const poolsAfterFirst = await db.pools.toArray();
    const coreDefaultsAfterFirst = await db.coreBoardDefaults.toArray();
    const templateAfterFirst = await db.recurringBoardTemplates.get('tmpl-1');

    await runMigrationV16({} as Transaction);
    const poolsAfterSecond = await db.pools.toArray();
    const coreDefaultsAfterSecond = await db.coreBoardDefaults.toArray();
    const templateAfterSecond = await db.recurringBoardTemplates.get('tmpl-1');

    expect(poolsAfterSecond).toHaveLength(poolsAfterFirst.length);
    expect(coreDefaultsAfterSecond).toHaveLength(coreDefaultsAfterFirst.length);
    // Same pool ids — nothing re-minted.
    expect(poolsAfterSecond.map((p) => p.id).sort()).toEqual(
      poolsAfterFirst.map((p) => p.id).sort(),
    );
    // Template's poolIds/version untouched by the second run.
    expect(templateAfterSecond?.poolIds).toEqual(templateAfterFirst?.poolIds);
    expect(templateAfterSecond?.version).toBe(templateAfterFirst?.version);
  });

  it('leaves an already-migrated template (poolIds already set) untouched', async () => {
    await db.recurringBoardTemplates.add(
      seedTemplate({
        id: 'tmpl-already',
        poolIds: ['existing-pool'],
        manualTaskIds: ['manual-1'],
        removedTaskIds: [],
        version: 3,
      }),
    );

    await runMigrationV16({} as Transaction);

    expect(await db.pools.count()).toBe(0);
    const template = await db.recurringBoardTemplates.get('tmpl-already');
    expect(template?.poolIds).toEqual(['existing-pool']);
    expect(template?.manualTaskIds).toEqual(['manual-1']);
    expect(template?.version).toBe(3);
  });

  it('leaves an already-soft-deleted DefaultPool untouched (no double-mint)', async () => {
    await db.defaultPools.add(
      seedDefaultPool({ id: 'dp-gone', timeframe: Timeframe.MONTHLY, isDeleted: true, deletedAt: NOW }),
    );

    await runMigrationV16({} as Transaction);

    expect(await db.pools.count()).toBe(0);
    expect(await db.coreBoardDefaults.count()).toBe(0);
  });
});
