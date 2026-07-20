import { afterEach, describe, expect, it } from 'vitest';
import type { Transaction } from 'dexie';
import {
  CenterSquareType,
  PoolSchema,
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

  // Review finding C2 (P1 final fix wave): the migration must mint
  // DETERMINISTIC ids (uuidv5, keyed off the source row's id), not random
  // UUIDs — two devices independently migrating the same DefaultPool /
  // RecurringBoardTemplate row must derive the SAME Pool/CoreBoardDefault
  // id, or sync converges on duplicate rows per source that can never be
  // merged back down after the fact.
  describe('C2 — deterministic migration mint ids', () => {
    it('mints the SAME Pool + CoreBoardDefault id for a DefaultPool row across two independent fresh-device runs', async () => {
      // "Fresh run 1" — device A migrates its local copy of dp-shared.
      await db.defaultPools.add(seedDefaultPool({ id: 'dp-shared', timeframe: Timeframe.YEARLY }));
      await runMigrationV16({} as Transaction);
      const poolIdRun1 = (await db.pools.toArray())[0].id;
      const coreDefaultIdRun1 = (await db.coreBoardDefaults.toArray())[0].id;

      // Reset local state to simulate a second, independent device that
      // never saw device A's migration output — only the SAME source
      // DefaultPool row (same id, re-seeded un-migrated).
      await db.pools.clear();
      await db.coreBoardDefaults.clear();
      await db.defaultPools.clear();
      await db.syncQueue.clear();
      await db.defaultPools.add(seedDefaultPool({ id: 'dp-shared', timeframe: Timeframe.YEARLY }));

      // "Fresh run 2" — device B migrates the same source row independently.
      await runMigrationV16({} as Transaction);
      const poolIdRun2 = (await db.pools.toArray())[0].id;
      const coreDefaultIdRun2 = (await db.coreBoardDefaults.toArray())[0].id;

      expect(poolIdRun2).toBe(poolIdRun1);
      expect(coreDefaultIdRun2).toBe(coreDefaultIdRun1);
    });

    it('mints the SAME Pool id for a RecurringBoardTemplate across two independent fresh-device runs', async () => {
      await db.recurringBoardTemplates.add(seedTemplate({ id: 'tmpl-shared' }));
      await runMigrationV16({} as Transaction);
      const poolIdRun1 = (await db.pools.toArray())[0].id;

      await db.pools.clear();
      await db.recurringBoardTemplates.clear();
      await db.syncQueue.clear();
      await db.recurringBoardTemplates.add(seedTemplate({ id: 'tmpl-shared' }));

      await runMigrationV16({} as Transaction);
      const poolIdRun2 = (await db.pools.toArray())[0].id;

      expect(poolIdRun2).toBe(poolIdRun1);
    });

    // Cross-platform pin: this exact uuidv5 derivation is asserted
    // BYTE-IDENTICAL in the iOS XCTest suite
    // (`OYBCTests/PoolsCoreBoardDefaultsMigrationTests.swift`,
    // `test_deterministicMintIds_matchCrossPlatformFixture`). If this
    // literal ever needs to change, the Swift literal MUST change with it
    // in the same PR — the whole point of uuidv5 here is that both
    // platforms derive the identical id from the identical source id.
    it('derives the exact fixture id for a known DefaultPool id (locks the uuidv5 namespace strings cross-platform)', async () => {
      await db.defaultPools.add(
        seedDefaultPool({ id: 'dp-fixture-1', timeframe: Timeframe.DAILY }),
      );
      await db.recurringBoardTemplates.add(seedTemplate({ id: 'tmpl-fixture-1' }));

      await runMigrationV16({} as Transaction);

      const pools = await db.pools.toArray();
      const coreDefaults = await db.coreBoardDefaults.toArray();

      const mintedPoolForDefaultPool = pools.find((p) => p.name === 'Daily default');
      const mintedPoolForTemplate = pools.find((p) => p.name === 'Daily Workout pool');

      expect(mintedPoolForDefaultPool?.id).toBe('e1105aeb-04bc-58ca-936c-be32ea86437b');
      expect(coreDefaults[0]?.id).toBe('94e67c0c-b1d1-50f6-90ab-6cedf9e60efc');
      expect(mintedPoolForTemplate?.id).toBe('f11ff2bb-283e-5867-8348-253dc1fe46db');
    });
  });

  // Review finding I1 (P1 final fix wave): a 120-char RecurringBoardTemplate
  // name ("` pool`" appended = 125 chars unclamped) must mint a Pool name
  // that's still ≤120 and passes PoolSchema — otherwise the pulled doc is
  // rejected on any other device (`applyRemoteSubdoc`'s Zod validation).
  it('I1 — a 120-char template name mints a Pool name clamped to exactly 120 chars, valid per PoolSchema', async () => {
    const name120 = 'A'.repeat(120);
    await db.recurringBoardTemplates.add(
      seedTemplate({
        id: 'tmpl-long',
        name: name120,
        seedTaskIds: ['11111111-1111-4111-8111-111111111111'],
      }),
    );

    await runMigrationV16({} as Transaction);

    const pools = await db.pools.toArray();
    expect(pools).toHaveLength(1);
    expect(pools[0].name.length).toBe(120);
    expect(pools[0].name).toBe(`${'A'.repeat(115)} pool`);
    expect(PoolSchema.safeParse(pools[0]).success).toBe(true);
  });
});
