import type { Pool } from '@oybc/shared';
import { softDeletePool } from '../../db/operations/pools';
import { savePoolWithStagedEdits } from '../../db/operations/poolSave';
import type { TaskEditPatch } from '../../db/taskEditPatch';

/** The fields `PoolEditSheet` collects before a save. */
export interface PoolEditSheetSaveInput {
  name: string;
  taskIds: string[];
  /** Inline row edits staged in the editor (task id → patch). Applied in
   *  the SAME transaction as the membership write — see `savePoolFromSheet`.
   *  Omitted ⇒ none. */
  stagedEdits?: Map<string, TaskEditPatch>;
}

/** `PoolSchema.name` bound (`packages/shared/src/validation/schemas.ts`) —
 *  a name that saves past this fails Zod on the next pull (same class as
 *  P1's minted-name clamp, a different entry point: this one is
 *  user-typed, so it's enforced both as the input's `maxLength` AND here
 *  as a save-time backstop against paste/IME input that bypasses the DOM
 *  attribute). Mirrors iOS's `PoolEditSheetView.nameMaxLength`. */
export const POOL_NAME_MAX_LENGTH = 120;

/**
 * Persists a pool-editor save — extracted from the component so the
 * create-vs-update branch (and the P1 CRUD ops it delegates to) has a
 * directly testable seam without a component-render harness (this repo
 * has none; see CLAUDE.md's iOS-only snapshot-test guidance — web has no
 * equivalent, so pure/op-level functions are how UI logic gets covered).
 *
 * `pool === undefined` ⇒ create mode (`createPool`); otherwise updates the
 * existing row (`updatePool`). Throws if the trimmed name exceeds
 * `POOL_NAME_MAX_LENGTH` (a >120-char name would otherwise save locally,
 * push, then fail `PoolSchema` on the next pull — I-1) or if `updatePool`
 * reports the pool no longer exists (soft-deleted or removed out from
 * under the open sheet).
 *
 * The staged inline edits and the membership write run in ONE Dexie `rw`
 * transaction (the wizard's apply-staged-edits precedent first, then
 * `createPool` / `updatePool`): a thrown edit — or a failed membership
 * write — rolls the whole save back, so nothing is half-applied.
 */
export async function savePoolFromSheet(
  userId: string,
  pool: Pool | undefined,
  input: PoolEditSheetSaveInput,
): Promise<Pool> {
  const name = input.name.trim();
  if (name.length > POOL_NAME_MAX_LENGTH) {
    throw new Error(`Pool name must be ${POOL_NAME_MAX_LENGTH} characters or fewer.`);
  }
  return savePoolWithStagedEdits(userId, pool, { name, taskIds: input.taskIds, stagedEdits: input.stagedEdits });
}

/**
 * Persists a `PoolEditSheet` delete. Thin wrapper (matches
 * `savePoolFromSheet`'s shape) — `softDeletePool` already documents the
 * derived-detachment contract (never cascades to consumers or tasks).
 */
export async function deletePoolFromSheet(pool: Pool): Promise<void> {
  await softDeletePool(pool.id);
}
