import { db } from '../internal';
import type {
  DefaultPool,
  CreateDefaultPoolInput,
  UpdateDefaultPoolInput,
  Timeframe,
} from '@oybc/shared';
import { SyncOperationType } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * DefaultPool CRUD operations (Phase 6.X — Default Pools).
 *
 * One pool per `(userId, timeframe)`. Uniqueness is enforced at the
 * application layer (no DB constraint): `upsertDefaultPool` queries by
 * `[userId+timeframe]` and creates-or-updates accordingly. Direct calls
 * to `createDefaultPool` from UI code should be avoided in favor of
 * `upsertDefaultPool`.
 *
 * Each write enqueues a `syncQueue` entry inline (mirror of
 * `recurringBoardTemplates.ts` and `boards.ts`).
 */

/**
 * Fetch all non-deleted pools for a user, indexed by timeframe.
 * Used by the Profile section to render the per-timeframe summary.
 */
export async function fetchDefaultPools(userId: string): Promise<DefaultPool[]> {
  return db.defaultPools
    .filter((p) => p.userId === userId && !p.isDeleted)
    .toArray();
}

/**
 * Fetch the (at most one) non-deleted pool for `(userId, timeframe)`.
 * Returns undefined when the user hasn't set one up. Used by the wizard
 * prefill path and the editor page hydration.
 */
export async function fetchDefaultPool(
  userId: string,
  timeframe: Timeframe,
): Promise<DefaultPool | undefined> {
  return db.defaultPools
    .filter((p) => p.userId === userId && p.timeframe === timeframe && !p.isDeleted)
    .first();
}

/**
 * Create a new pool. Prefer `upsertDefaultPool` from UI code — this
 * helper assumes the caller has already verified no pool exists for the
 * `(userId, timeframe)` pair.
 */
export async function createDefaultPool(
  userId: string,
  input: CreateDefaultPoolInput,
): Promise<DefaultPool> {
  const now = currentTimestamp();
  const pool: DefaultPool = {
    id: generateUUID(),
    userId,
    timeframe: input.timeframe,
    taskIds: [...input.taskIds],
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };

  await db.defaultPools.add(pool);
  await addToSyncQueue('defaultPools', pool.id, SyncOperationType.CREATE, pool);
  return pool;
}

/**
 * Update an existing pool's `taskIds`. Bumps `version` + `updatedAt`.
 * Returns the updated row (or undefined when the id doesn't exist).
 */
export async function updateDefaultPool(
  id: string,
  updates: UpdateDefaultPoolInput,
): Promise<DefaultPool | undefined> {
  const existing = await db.defaultPools.get(id);
  if (!existing) return undefined;

  const patch: Partial<DefaultPool> = {
    taskIds: updates.taskIds ? [...updates.taskIds] : undefined,
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  };
  for (const key of Object.keys(patch) as (keyof typeof patch)[]) {
    if (patch[key] === undefined) delete patch[key];
  }

  await db.defaultPools.update(id, patch);
  const updated = await db.defaultPools.get(id);
  if (updated) {
    await addToSyncQueue('defaultPools', id, SyncOperationType.UPDATE, updated);
  }
  return updated;
}

/**
 * Atomic upsert by `(userId, timeframe)`. Preferred UI-side entry point
 * — guarantees the per-timeframe uniqueness invariant without leaking
 * the create-vs-update decision to callers.
 */
export async function upsertDefaultPool(
  userId: string,
  timeframe: Timeframe,
  taskIds: string[],
): Promise<DefaultPool> {
  const existing = await fetchDefaultPool(userId, timeframe);
  if (existing) {
    const updated = await updateDefaultPool(existing.id, { taskIds });
    return updated ?? existing;
  }
  return createDefaultPool(userId, { timeframe, taskIds });
}

/**
 * Soft-delete a pool. Useful when the user wants to clear a timeframe's
 * pool entirely (vs setting taskIds to []). Bumps `version` so LWW
 * treats the deletion as later-wins.
 */
export async function softDeleteDefaultPool(id: string): Promise<void> {
  const existing = await db.defaultPools.get(id);
  if (!existing) return;

  await db.defaultPools.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });

  const tombstone = await db.defaultPools.get(id);
  if (tombstone) {
    await addToSyncQueue('defaultPools', id, SyncOperationType.DELETE, tombstone);
  }
}
