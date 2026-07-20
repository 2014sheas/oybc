import { db } from '../internal';
import type {
  CoreBoardDefault,
  CreateCoreBoardDefaultInput,
  UpdateCoreBoardDefaultInput,
  Timeframe,
} from '@oybc/shared';
import { SyncOperationType } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * CoreBoardDefault CRUD operations (Task Pools + Recurring Boards Rework,
 * P1). Replaces `DefaultPool` — see `packages/shared/src/types/coreBoardDefault.ts`
 * for the full contract.
 *
 * One row per `(userId, timeframe)`. Uniqueness is enforced at the
 * application layer (no DB constraint): `upsertCoreBoardDefault` queries
 * by `[userId+timeframe]` and creates-or-updates accordingly, exactly
 * like `defaultPools.ts`'s `upsertDefaultPool`.
 *
 * Each write enqueues a `syncQueue` entry inline (mirror of
 * `defaultPools.ts`).
 */

/**
 * Fetch all non-deleted CoreBoardDefault rows for a user, indexed by
 * timeframe. Used by the P7 Board-settings page's per-timeframe summary.
 */
export async function fetchCoreBoardDefaults(userId: string): Promise<CoreBoardDefault[]> {
  return db.coreBoardDefaults
    .filter((d) => d.userId === userId && !d.isDeleted)
    .toArray();
}

/**
 * Fetch the (at most one) non-deleted CoreBoardDefault for
 * `(userId, timeframe)`. Returns undefined when the user hasn't set one
 * up. Used by the core-board setup prefill path (P5).
 */
export async function fetchCoreBoardDefault(
  userId: string,
  timeframe: Timeframe,
): Promise<CoreBoardDefault | undefined> {
  return db.coreBoardDefaults
    .filter((d) => d.userId === userId && d.timeframe === timeframe && !d.isDeleted)
    .first();
}

/**
 * Create a new CoreBoardDefault row. Prefer `upsertCoreBoardDefault` from
 * UI code — this helper assumes the caller has already verified no row
 * exists for the `(userId, timeframe)` pair. NOT used by the P1 migration
 * (`migrationV16.ts`) — that migration inserts directly via
 * `db.coreBoardDefaults.add()` (it needs a deterministic, uuidv5-derived
 * id, not this helper's `generateUUID()`) inside its own upgrade
 * transaction, which this helper doesn't participate in.
 */
export async function createCoreBoardDefault(
  userId: string,
  input: CreateCoreBoardDefaultInput,
): Promise<CoreBoardDefault> {
  const now = currentTimestamp();
  const coreDefault: CoreBoardDefault = {
    id: generateUUID(),
    userId,
    timeframe: input.timeframe,
    corePoolIds: [...input.corePoolIds],
    coreDefaultTaskIds: [...input.coreDefaultTaskIds],
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };

  await db.coreBoardDefaults.add(coreDefault);
  await addToSyncQueue('coreBoardDefaults', coreDefault.id, SyncOperationType.CREATE, coreDefault);
  return coreDefault;
}

/**
 * Update an existing CoreBoardDefault's `corePoolIds` and/or
 * `coreDefaultTaskIds`. Bumps `version` + `updatedAt`. Returns the
 * updated row (or undefined when the id doesn't exist).
 */
export async function updateCoreBoardDefault(
  id: string,
  updates: UpdateCoreBoardDefaultInput,
): Promise<CoreBoardDefault | undefined> {
  const existing = await db.coreBoardDefaults.get(id);
  if (!existing) return undefined;

  const patch: Partial<CoreBoardDefault> = {
    corePoolIds: updates.corePoolIds ? [...updates.corePoolIds] : undefined,
    coreDefaultTaskIds: updates.coreDefaultTaskIds
      ? [...updates.coreDefaultTaskIds]
      : undefined,
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  };
  for (const key of Object.keys(patch) as (keyof typeof patch)[]) {
    if (patch[key] === undefined) delete patch[key];
  }

  await db.coreBoardDefaults.update(id, patch);
  const updated = await db.coreBoardDefaults.get(id);
  if (updated) {
    await addToSyncQueue('coreBoardDefaults', id, SyncOperationType.UPDATE, updated);
  }
  return updated;
}

/**
 * Atomic upsert by `(userId, timeframe)`. Preferred UI-side entry point
 * (P5/P7) — guarantees the per-timeframe uniqueness invariant without
 * leaking the create-vs-update decision to callers.
 */
export async function upsertCoreBoardDefault(
  userId: string,
  timeframe: Timeframe,
  updates: { corePoolIds?: string[]; coreDefaultTaskIds?: string[] },
): Promise<CoreBoardDefault> {
  const existing = await fetchCoreBoardDefault(userId, timeframe);
  if (existing) {
    const updated = await updateCoreBoardDefault(existing.id, updates);
    return updated ?? existing;
  }
  return createCoreBoardDefault(userId, {
    timeframe,
    corePoolIds: updates.corePoolIds ?? [],
    coreDefaultTaskIds: updates.coreDefaultTaskIds ?? [],
  });
}

/**
 * Soft-delete a CoreBoardDefault row. Bumps `version` so LWW treats the
 * deletion as later-wins.
 */
export async function softDeleteCoreBoardDefault(id: string): Promise<void> {
  const existing = await db.coreBoardDefaults.get(id);
  if (!existing) return;

  await db.coreBoardDefaults.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });

  const tombstone = await db.coreBoardDefaults.get(id);
  if (tombstone) {
    await addToSyncQueue('coreBoardDefaults', id, SyncOperationType.DELETE, tombstone);
  }
}
