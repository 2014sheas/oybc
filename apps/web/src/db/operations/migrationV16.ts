import type { Transaction } from 'dexie';
import { db } from '../internal';
import {
  SyncOperationType,
  SyncStatus,
  Timeframe,
  migrationDefaultPoolToPoolId,
  migrationDefaultPoolToCoreBoardDefaultId,
  migrationTemplateToPoolId,
  clampMintedPoolName,
  type Pool,
  type CoreBoardDefault,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * Dexie v16 data migration — Task Pools + Recurring Boards Rework
 * first-launch backfill (docs/POOLS_RECURRING.md §Migration). Twin of iOS
 * `MigrationV25Helpers.swift`. Runs inside the v16 upgrade callback (one
 * atomic transaction), after v15 created the `pools` / `coreBoardDefaults`
 * stores empty. Two steps, each idempotent by state (no marker table):
 *
 *   1. Each non-deleted `DefaultPool` → a `Pool` named "<Timeframe> default"
 *      + a `CoreBoardDefault` with `corePoolIds: [pool.id]`; the
 *      `DefaultPool` is then soft-deleted. A re-run reads only
 *      `!isDeleted` rows, so it does nothing.
 *   2. Each `RecurringBoardTemplate` with `poolIds` ABSENT → its
 *      `seedTaskIds` extracted into a `Pool` named "<name> pool"; the
 *      template is stamped `poolIds: [pool.id]`, `manualTaskIds: []`,
 *      `removedTaskIds: []` (`seedTaskIds` left verbatim, decode-compat).
 *      A re-run reads only `poolIds === undefined` rows, so it does nothing.
 *      Soft-deleted templates are migrated too (the minted pool is inert).
 *
 * Both steps enqueue sync entries directly (NOT `addToSyncQueue`, which
 * opens its own transaction and isn't upgrade-tx-aware).
 *
 * Determinism: minted ids use `uuidv5` (`migrationDefaultPoolToPoolId` /
 * `migrationDefaultPoolToCoreBoardDefaultId` / `migrationTemplateToPoolId`),
 * never `generateUUID()`, so two devices migrating the same source row
 * independently mint the SAME id instead of converging into duplicates
 * after sync (the `backfillTaskEventId` precedent). The namespace strings
 * must stay byte-identical to the Swift port (cross-platform id-literal
 * test in each suite).
 *
 * Name clamp: a template name can be 120 chars; appending " pool" would
 * exceed `PoolSchema`'s 120-char max and fail Zod on the next device's pull
 * (the local write succeeds, silently stranding the doc on one device).
 * `clampMintedPoolName` clamps the source text at both mint sites below.
 *
 * @param _tx The Dexie upgrade transaction (unused directly — Dexie binds
 *            all `db` table ops to the active transaction inside the
 *            callback).
 */
export async function runMigrationV16(_tx: Transaction): Promise<void> {
  await migrateDefaultPools();
  await migrateRecurringBoardTemplates();
}

/** "<Timeframe> default" pool-naming label. `DefaultPool`/`CoreBoardDefault`
 *  both exclude CUSTOM/INDEFINITE, so those two are unreachable here —
 *  included only so the map is total over `Timeframe` (exhaustiveness). */
const TIMEFRAME_DEFAULT_LABEL: Record<Timeframe, string> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
  [Timeframe.CUSTOM]: 'Custom',
  [Timeframe.INDEFINITE]: 'Ongoing',
};

async function migrateDefaultPools(): Promise<void> {
  const now = currentTimestamp();
  const defaultPools = await db.defaultPools.filter((p) => !p.isDeleted).toArray();

  for (const dp of defaultPools) {
    const pool: Pool = {
      id: migrationDefaultPoolToPoolId(dp.id),
      userId: dp.userId,
      name: clampMintedPoolName(TIMEFRAME_DEFAULT_LABEL[dp.timeframe], 'default'),
      taskIds: [...dp.taskIds],
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    };
    const coreDefault: CoreBoardDefault = {
      id: migrationDefaultPoolToCoreBoardDefaultId(dp.id),
      userId: dp.userId,
      timeframe: dp.timeframe,
      corePoolIds: [pool.id],
      coreDefaultTaskIds: [],
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    };

    await db.pools.add(pool);
    await db.coreBoardDefaults.add(coreDefault);
    await db.defaultPools.update(dp.id, {
      isDeleted: true,
      deletedAt: now,
      updatedAt: now,
      version: (dp.version ?? 0) + 1,
    });

    await enqueueMigrationSync('pools', pool.id, SyncOperationType.CREATE, pool);
    await enqueueMigrationSync(
      'coreBoardDefaults',
      coreDefault.id,
      SyncOperationType.CREATE,
      coreDefault,
    );
    const tombstone = await db.defaultPools.get(dp.id);
    if (tombstone) {
      await enqueueMigrationSync('defaultPools', dp.id, SyncOperationType.DELETE, tombstone);
    }
  }
}

async function migrateRecurringBoardTemplates(): Promise<void> {
  const now = currentTimestamp();
  // `poolIds === undefined` is the "genuinely un-migrated" legacy shape
  // (see RecurringBoardTemplate's doc in @oybc/shared). Deliberately not
  // filtered by `isDeleted`: every RecurringBoardTemplate row gets its
  // seedTaskIds carried forward.
  const templates = await db.recurringBoardTemplates
    .filter((t) => t.poolIds === undefined)
    .toArray();

  for (const t of templates) {
    const pool: Pool = {
      id: migrationTemplateToPoolId(t.id),
      userId: t.userId,
      name: clampMintedPoolName(t.name, 'pool'),
      taskIds: [...t.seedTaskIds],
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    };

    const updatedTemplate: RecurringBoardTemplate = {
      ...t,
      poolIds: [pool.id],
      manualTaskIds: [],
      removedTaskIds: [],
      updatedAt: now,
      version: (t.version ?? 0) + 1,
    };

    await db.pools.add(pool);
    await db.recurringBoardTemplates.put(updatedTemplate);

    await enqueueMigrationSync('pools', pool.id, SyncOperationType.CREATE, pool);
    await enqueueMigrationSync(
      'recurringBoardTemplates',
      updatedTemplate.id,
      SyncOperationType.UPDATE,
      updatedTemplate,
    );
  }
}

/** Enqueue a sync-queue row directly against the upgrade transaction
 *  (bypasses `addToSyncQueue`, which opens its own transaction — not
 *  upgrade-tx-aware). Mirrors `migrationV13`/`migrationV14`. */
async function enqueueMigrationSync(
  entityType: string,
  entityId: string,
  operationType: SyncOperationType,
  payload: unknown,
): Promise<void> {
  await db.syncQueue.add({
    id: generateUUID(),
    entityType,
    entityId,
    operationType,
    payload: JSON.stringify(payload),
    status: SyncStatus.PENDING,
    retryCount: 0,
    createdAt: currentTimestamp(),
    priority: 0,
  });
}
