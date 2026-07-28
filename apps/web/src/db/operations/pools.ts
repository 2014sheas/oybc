import { db } from '../internal';
import type { Pool, CreatePoolInput, UpdatePoolInput } from '@oybc/shared';
import { SyncOperationType } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';

/**
 * Pool CRUD operations (Task Pools + Recurring Boards Rework, P1).
 *
 * A `Pool` is a user-named collection of task REFERENCES (never copies) —
 * see `packages/shared/src/types/pool.ts` for the full contract (no board
 * actions on pool surfaces, derived/non-cascaded detachment, health
 * computed at read time). Modeled directly on `defaultPools.ts`; the only
 * structural difference is that a Pool is user-named (many per user, no
 * `(userId, timeframe)` uniqueness) rather than one-per-timeframe.
 *
 * Each write enqueues a `syncQueue` entry inline (mirror of
 * `defaultPools.ts` / `recurringBoardTemplates.ts`).
 */

/**
 * Fetch all non-deleted pools for a user. Used by the Tasks-tab Pools
 * segment (P2) and by the legacy template write-through / migration to
 * look up a specific pool's current `taskIds`.
 */
export async function fetchPools(userId: string): Promise<Pool[]> {
  return db.pools.filter((p) => p.userId === userId && !p.isDeleted).toArray();
}

/**
 * Fetch a single pool by id (regardless of `isDeleted` — callers that
 * need to distinguish should check the returned row).
 */
export async function fetchPool(id: string): Promise<Pool | undefined> {
  return db.pools.get(id);
}

/**
 * Fetch multiple pools by id in one query. Used by `resolveMix` callers
 * (spawn path, wizard template-mix hydration) that already have a
 * `poolIds` array and need a `poolsById` lookup.
 */
export async function fetchPoolsByIds(ids: string[]): Promise<Pool[]> {
  if (ids.length === 0) return [];
  return db.pools.where('id').anyOf(ids).toArray();
}

/**
 * Create a new pool.
 */
export async function createPool(userId: string, input: CreatePoolInput): Promise<Pool> {
  const now = currentTimestamp();
  const pool: Pool = {
    id: generateUUID(),
    userId,
    name: input.name.trim(),
    taskIds: [...input.taskIds],
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };

  await db.pools.add(pool);
  await addToSyncQueue('pools', pool.id, SyncOperationType.CREATE, pool);
  return pool;
}

/**
 * Update an existing pool's `name` and/or `taskIds`. Bumps `version` +
 * `updatedAt`. Returns the updated row (or undefined when the id doesn't
 * exist).
 */
export async function updatePool(
  id: string,
  updates: UpdatePoolInput,
): Promise<Pool | undefined> {
  const existing = await db.pools.get(id);
  if (!existing) return undefined;

  const patch: Partial<Pool> = {
    name: updates.name !== undefined ? updates.name.trim() : undefined,
    taskIds: updates.taskIds ? [...updates.taskIds] : undefined,
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  };
  for (const key of Object.keys(patch) as (keyof typeof patch)[]) {
    if (patch[key] === undefined) delete patch[key];
  }

  await db.pools.update(id, patch);
  const updated = await db.pools.get(id);
  if (updated) {
    await addToSyncQueue('pools', id, SyncOperationType.UPDATE, updated);
  }
  return updated;
}

/**
 * Soft-delete a pool. Never cascades to the tasks it references, and
 * never cascades to consumers (spawn records / core defaults) that
 * pulled it in — detachment is derived at read time (`resolveMix` /
 * core-defaults resolution skip `isDeleted` pools), matching
 * `Pool`'s docstring. Bumps `version` so LWW treats the deletion as
 * later-wins.
 */
export async function softDeletePool(id: string): Promise<void> {
  const existing = await db.pools.get(id);
  if (!existing) return;

  await db.pools.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });

  const tombstone = await db.pools.get(id);
  if (tombstone) {
    await addToSyncQueue('pools', id, SyncOperationType.DELETE, tombstone);
  }
}
