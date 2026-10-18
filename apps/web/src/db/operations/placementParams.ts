import { db } from '../internal';
import {
  SyncOperationType,
  withNormalizedPlacementFields,
  type BoardTask,
  type CountKind,
  type PlacementChildTarget,
} from '@oybc/shared';
import { currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForBoardId } from './orchestration';

/**
 * placementParams.ts — the one writer of a placement's per-board parameters
 * (TASK_WINDOW_REWORK slice 3a, "Writers emit parameters, not rows").
 */

/**
 * A partial update of a placement's parameter fields. `undefined` leaves a
 * field as it is; `null` CLEARS it (the field becomes ABSENT on the row, which
 * `CLEARABLE_FIELDS_BY_COLLECTION.boardTasks` syncs as a delete).
 */
export interface PlacementParamsPatch {
  targetOverride?: number | null;
  targetKind?: CountKind | null;
  childTargets?: PlacementChildTarget[] | null;
  titleOverride?: string | null;
}

/**
 * Merge `patch` onto a BoardTask's parameter fields, version-bump it, enqueue
 * an UPDATE and re-derive the owning board. Clearing `targetOverride` also
 * clears `targetKind` (a kind never stands alone). Joins the caller's Dexie
 * transaction when there is one (scope: boardTasks, boards, tasks,
 * compoundChildren, taskEvents, syncQueue). A missing / deleted placement, or
 * one on a sealed or deleted board, is a no-op; a patch that leaves the
 * stored fields unchanged writes nothing.
 *
 * @param boardTaskId - The placement to patch.
 * @param patch - The fields to set (value) or clear (`null`).
 * @param now - ISO8601 write instant.
 */
export async function setPlacementParams(
  boardTaskId: string,
  patch: PlacementParamsPatch,
  now: string = currentTimestamp(),
): Promise<void> {
  await db.transaction(
    'rw',
    [db.boardTasks, db.boards, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      const existing = await db.boardTasks.get(boardTaskId);
      if (!existing || existing.isDeleted) return;
      // Sealed-board guard — re-fetched inside the write txn.
      const owningBoard = await db.boards.get(existing.boardId);
      if (!owningBoard || owningBoard.isDeleted || owningBoard.sealedAt) return;

      const merged: Partial<BoardTask> = {
        targetOverride: existing.targetOverride,
        targetKind: existing.targetKind,
        childTargets: existing.childTargets,
        titleOverride: existing.titleOverride,
      };
      if (patch.targetOverride === null) {
        merged.targetOverride = undefined;
        merged.targetKind = undefined;
      } else {
        if (patch.targetOverride !== undefined) merged.targetOverride = patch.targetOverride;
        if (patch.targetKind !== undefined) merged.targetKind = patch.targetKind ?? undefined;
      }
      if (patch.childTargets !== undefined) merged.childTargets = patch.childTargets ?? undefined;
      if (patch.titleOverride !== undefined) merged.titleOverride = patch.titleOverride ?? undefined;

      const { targetOverride: _t, targetKind: _k, childTargets: _c, titleOverride: _o, ...base } = existing;
      const patched: BoardTask = withNormalizedPlacementFields({
        ...base,
        ...merged,
        updatedAt: now,
        version: (existing.version ?? 0) + 1,
      } as BoardTask);

      const fieldsOf = (bt: BoardTask): string =>
        JSON.stringify([bt.targetOverride, bt.targetKind, bt.childTargets, bt.titleOverride]);
      if (fieldsOf(withNormalizedPlacementFields({ ...existing })) === fieldsOf(patched)) return;

      await db.boardTasks.put(patched);
      await addToSyncQueue('boardTasks', boardTaskId, SyncOperationType.UPDATE, patched, 0);
      await runBoardCascadeForBoardId(existing.boardId);
    },
  );
}
