import type { Pool } from '@oybc/shared';
import { createPool, softDeletePool, updatePool } from '../../db/operations/pools';

/** The fields `PoolEditSheet` collects before a save. */
export interface PoolEditSheetSaveInput {
  name: string;
  taskIds: string[];
}

/**
 * Persists a `PoolEditSheet` save — extracted from the component so the
 * create-vs-update branch (and the P1 CRUD ops it delegates to) has a
 * directly testable seam without a component-render harness (this repo
 * has none; see CLAUDE.md's iOS-only snapshot-test guidance — web has no
 * equivalent, so pure/op-level functions are how UI logic gets covered).
 *
 * `pool === undefined` ⇒ create mode (`createPool`); otherwise updates the
 * existing row (`updatePool`). Throws if `updatePool` reports the pool no
 * longer exists (soft-deleted or removed out from under the open sheet).
 */
export async function savePoolFromSheet(
  userId: string,
  pool: Pool | undefined,
  input: PoolEditSheetSaveInput,
): Promise<Pool> {
  const name = input.name.trim();
  if (pool) {
    const updated = await updatePool(pool.id, { name, taskIds: input.taskIds });
    if (!updated) {
      throw new Error('Pool no longer exists');
    }
    return updated;
  }
  return createPool(userId, { name, taskIds: input.taskIds });
}

/**
 * Persists a `PoolEditSheet` delete. Thin wrapper (matches
 * `savePoolFromSheet`'s shape) — `softDeletePool` already documents the
 * derived-detachment contract (never cascades to consumers or tasks).
 */
export async function deletePoolFromSheet(pool: Pool): Promise<void> {
  await softDeletePool(pool.id);
}
