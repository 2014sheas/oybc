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
 * first-launch backfill (docs/POOLS_RECURRING.md §Migration).
 *
 * Runs inside the v16 upgrade callback (one atomic transaction), AFTER v15
 * created the `pools` / `coreBoardDefaults` stores empty. Two independent
 * steps, both idempotent by construction (a second run is a no-op — see
 * each step's guard below), mirroring the state-based idempotency pattern
 * used by `migrationV13`/`migrationV14` (no separate "migration completed"
 * marker table):
 *
 *   1. Each non-deleted `DefaultPool` row → a `Pool` named
 *      "<Timeframe> default" + a `CoreBoardDefault` row for that timeframe
 *      with `corePoolIds: [newPool.id]`, `coreDefaultTaskIds: []`. The
 *      `DefaultPool` row is then soft-deleted (tombstone drains to
 *      Firestore via the push path per the known-collections precedent;
 *      `defaultPools` joins `LEGACY_PULL_SKIP_COLLECTIONS`).
 *
 *      Idempotency: the loop only reads `!isDeleted` DefaultPool rows. A
 *      second run sees every row already soft-deleted by the first run,
 *      so it does nothing.
 *
 *   2. Each `RecurringBoardTemplate` whose `poolIds` field is ABSENT (the
 *      "genuinely un-migrated" half of `isLegacyShapedRecord`'s two cases
 *      — see `packages/shared/src/algorithms/poolMix.ts`) has its
 *      `seedTaskIds` extracted into a `Pool` named "<template name> pool";
 *      the template is stamped with `poolIds: [newPool.id]`,
 *      `manualTaskIds: []`, `removedTaskIds: []`. `seedTaskIds` itself is
 *      left VERBATIM (decode-compat, the `lastSyncedCount` precedent) and
 *      is never read by any P1+ code path after this migration runs.
 *
 *      Idempotency: the loop only reads templates where `poolIds` is
 *      `undefined`. A second run sees every row already stamped with a
 *      `poolIds` array (even an empty one would count — but this
 *      migration always stamps a length-1 array) by the first run, so it
 *      does nothing. Soft-deleted templates are still migrated (matches
 *      the doc's unconditional "Each RecurringBoardTemplate →" framing) —
 *      an already-deleted template's minted pool is simply inert, same
 *      as the template itself.
 *
 * Both steps enqueue sync entries directly (NOT `addToSyncQueue` — that
 * helper opens its own transaction and isn't upgrade-tx-aware; mirrors
 * `migrationV13`/`migrationV14`).
 *
 * Determinism (review finding C2): the minted `Pool` / `CoreBoardDefault`
 * ids use `uuidv5` (`migrationDefaultPoolToPoolId` /
 * `migrationDefaultPoolToCoreBoardDefaultId` / `migrationTemplateToPoolId`
 * in `@oybc/shared`'s `migrationHelpers.ts`), NOT `generateUUID()`. Two
 * devices independently migrating the same `DefaultPool` / template row
 * (e.g. both offline pre-sync, or racing the first post-upgrade launch)
 * must derive the SAME Pool/CoreBoardDefault id — a random id per device
 * would converge, post-sync, into two duplicate rows per source instead of
 * one. This mirrors the Windowed Completion backfill's
 * `backfillTaskEventId` precedent exactly. iOS's `MigrationV25Helpers.swift`
 * mints the identical ids via the Swift `UUIDv5` port — the namespace
 * strings must stay byte-identical across platforms (see that file + the
 * cross-platform id-literal test in each suite).
 *
 * The user-action-time LEGACY-CREATE mint paths (`wizardPersist.ts`,
 * iOS `BoardWizardPersist.swift`) are NOT part of this — those mint on one
 * device only (then sync as a normal CREATE), so random ids there are
 * correct and unchanged.
 *
 * Name clamp (review finding I1): a `RecurringBoardTemplate.name` can be
 * up to 120 chars; appending " pool" would push the minted Pool's name
 * over `PoolSchema`'s 120-char max, which fails Zod on the next device's
 * pull (the mint itself succeeds locally — no local Zod check on write —
 * so this silently strands the doc on ONE device). `clampMintedPoolName`
 * (`@oybc/shared`'s `poolMix.ts`) clamps the source text before appending
 * the suffix at both mint sites below, and at the two `wizardPersist.ts` /
 * `BoardWizardPersist.swift` legacy-create sites.
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
  // `poolIds === undefined` is the "genuinely un-migrated" half of
  // isLegacyShapedRecord's two cases — see poolMix.ts. Deliberately not
  // filtered by `isDeleted`: every RecurringBoardTemplate row gets its
  // seedTaskIds carried forward, matching the doc's unconditional framing.
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
