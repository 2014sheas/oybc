import type { Pool } from '@oybc/shared';
import { db } from '../internal';
import { currentTimestamp } from '../utils';
import type { TaskEditPatch } from '../taskEditPatch';
import { createPool, updatePool } from './pools';
import { applyStagedTaskEditsForWizardPersist } from './wizardBoard';

/**
 * Saves a pool's name + membership TOGETHER with the inline task edits
 * staged in the pool editor, in ONE Dexie `rw` transaction: the staged edits
 * first (the wizard's `applyStagedTaskEditsForWizardPersist` precedent —
 * counting blank titles derived through `applyPatchToTask`, compound
 * structure edits, board cascades), then `createPool` / `updatePool`. A
 * refused edit (`StagedEditError`), or a failed membership write, rolls the whole save back.
 *
 * @param userId - Owner of a newly created pool.
 * @param pool - The pool to update, or `undefined` to create.
 * @param input - The already-trimmed name, the raw ordered `taskIds`, and the staged edits.
 * @returns The persisted pool.
 * @throws If the pool no longer exists (edit mode) or any write fails.
 */
export async function savePoolWithStagedEdits(
  userId: string,
  pool: Pool | undefined,
  input: { name: string; taskIds: string[]; stagedEdits?: Map<string, TaskEditPatch> },
): Promise<Pool> {
  return db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.pools, db.syncQueue],
    async () => {
      // A removed row's edit never applies; strict mode then throws (rolling
      // the whole save back) on a missing task / invalid patch / link-guard
      // failure instead of silently dropping the user's edit (iOS twin).
      const kept = new Set(input.taskIds);
      const edits = new Map(
        [...(input.stagedEdits ?? new Map<string, TaskEditPatch>())].filter(([id]) => kept.has(id)),
      );
      await applyStagedTaskEditsForWizardPersist(edits, new Set(), currentTimestamp(), {
        strict: true,
      });
      if (pool) {
        const updated = await updatePool(pool.id, { name: input.name, taskIds: input.taskIds });
        if (!updated) throw new Error('Pool no longer exists');
        return updated;
      }
      return createPool(userId, { name: input.name, taskIds: input.taskIds });
    },
  );
}
