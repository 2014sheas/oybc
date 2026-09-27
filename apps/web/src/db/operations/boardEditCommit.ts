import { db } from '../internal';
import { CenterSquareType } from '@oybc/shared';
import { assertBoardEditable, updateBoardAndCascade } from './boards';
import {
  addBoardTaskToBoard,
  normalizeLegacyChosenCenter,
  removeBoardTaskFromBoard,
  reorderBoardTasks,
  setBoardTaskLocked,
  updateBoardTaskAndCascade,
} from './boardTasks';
import { updateTaskAndCascade, type UpdateTaskPatch } from './tasks';
import { persistWizardPendingTasks } from './wizardBoard';
import type { SquareDraftCell } from '../../hooks/squareEditCount';

/**
 * Board Edit redesign slice 3 (D15) — the squares editor's ONE Save
 * transaction. Extracted from `useBoardPlay.ts`'s `commitSquareEdits`
 * (board-integrity PR-4, item 3) and extended for staged ADDS (pending
 * tasks), the legacy-CHOSEN conversion (D2), and the center Free⇄Task
 * metadata patch (D16).
 */
export interface CommitSquareEditsInput {
  boardId: string;
  /** The final staged cells (adds/replaces/moves/locks already applied). */
  cells: SquareDraftCell[];
  /** ids of live placements (present at seed) absent from `cells` — staged removals. */
  removedBoardTaskIds: string[];
  taskOverrides: Map<string, UpdateTaskPatch>;
  /** Whether the on-disk board is still legacy CHOSEN (D2's conversion gate). */
  isLegacyChosenOnDisk: boolean;
  /** The draft's current lock state for the positional-center cell — `normalizeLegacyChosenCenter`'s `keepLocked`. */
  centerCellKeepLocked: boolean;
  /** The board-metadata patch (center Free⇄Task only, post-slice-3) — `undefined` when the center is unchanged. */
  centerPatch?: { centerSquareType: CenterSquareType.FREE | CenterSquareType.NONE };
}

/**
 * Commits every staged squares-editor edit in D15 order, inside ONE Dexie
 * transaction (board-integrity PR-4, item 3 — every helper called here
 * already opens its own `db.transaction('rw', [...])`, and Dexie joins the
 * ambient transaction when the requested scope is a subset, so wrapping the
 * sequence below is sufficient for atomicity):
 *
 *   0. `assertBoardEditable` — a sealed/deleted board throws first, so
 *      nothing below writes.
 *   1. Insert staged pending (not-yet-persisted) tasks, with
 *      `createdInWizard: false` (D14 — a deliberate library task, not a
 *      wizard draft; it must not be hidden from library-browse once
 *      removed from the board).
 *   2. `normalizeLegacyChosenCenter` if the on-disk board is still CHOSEN
 *      (D2) — runs regardless of what the rest of the session touched, as
 *      long as SOME edit landed here (Save is disabled at 0 edits).
 *   3. Replacements (`updateBoardTaskAndCascade`).
 *   4. Task-field overrides (`updateTaskAndCascade`).
 *   5. Removals (`removeBoardTaskFromBoard`) — BEFORE moves/adds so freed
 *      positions are not occupied.
 *   5b. UNLOCKS on pre-existing cells (`setBoardTaskLocked(false)`) — BEFORE
 *      moves: `reorderBoardTasks` rejects moving a row that is locked ON
 *      DISK, so "Unlock → hold-drag → Save" in one session must clear the
 *      lock first (slice-3 self-review).
 *   6. Moves (`reorderBoardTasks`).
 *   7. Adds (`addBoardTaskToBoard`, with `isLocked` from the draft).
 *   8. LOCKS on pre-existing cells (`setBoardTaskLocked(true)`) — AFTER
 *      moves, so "move → Lock in place" lands the row at its new slot first.
 *      A NEW cell's lock was already written by step 7.
 *   9. The center metadata patch (`updateBoardAndCascade`), when the
 *      Free⇄Task type changed.
 *
 * @param input - See {@link CommitSquareEditsInput}.
 */
export async function commitSquareEdits(input: CommitSquareEditsInput): Promise<void> {
  const {
    boardId,
    cells,
    removedBoardTaskIds,
    taskOverrides,
    isLegacyChosenOnDisk,
    centerCellKeepLocked,
    centerPatch,
  } = input;

  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      // 0. Editable guard — first, before any write.
      await assertBoardEditable(boardId);

      // 1. Insert staged pending tasks (createdInWizard: false — D14).
      const pendingWrites = cells
        .filter((c) => c.pending !== undefined)
        .map((c) => ({
          task: { ...c.pending!.task, createdInWizard: false },
          childTasks: c.pending!.childTasks.map((t) => ({ ...t, createdInWizard: false })),
          childLinks: c.pending!.childLinks,
        }));
      if (pendingWrites.length > 0) {
        const allowedIds = new Set(pendingWrites.map((p) => p.task.id));
        await persistWizardPendingTasks(pendingWrites, allowedIds);
      }

      // 2. Legacy-CHOSEN conversion (D2).
      if (isLegacyChosenOnDisk) {
        await normalizeLegacyChosenCenter(boardId, centerCellKeepLocked);
      }

      // 3. Replacements.
      for (const cell of cells) {
        if (cell.originalTaskId !== null && cell.taskId !== cell.originalTaskId) {
          await updateBoardTaskAndCascade(cell.cellId, cell.taskId);
        }
      }

      // 4. Task-field overrides.
      for (const [taskId, patch] of taskOverrides.entries()) {
        await updateTaskAndCascade(taskId, patch);
      }

      // 5. Removals — before moves/adds so freed cells aren't occupied.
      for (const removedId of removedBoardTaskIds) {
        await removeBoardTaskFromBoard(removedId);
      }

      // 5b. Unlocks on pre-existing cells — before moves (see doc above).
      for (const cell of cells) {
        if (cell.originalTaskId !== null && cell.originalLocked && !cell.isLocked) {
          await setBoardTaskLocked(cell.cellId, false);
        }
      }

      // 6. Moves (existing placements only — a staged add is created at its
      //    final position directly in step 7).
      const moves = cells
        .filter(
          (c) =>
            c.originalTaskId !== null && (c.row !== c.originalRow || c.col !== c.originalCol),
        )
        .map((c) => ({ boardTaskId: c.cellId, row: c.row, col: c.col }));
      if (moves.length > 0) {
        await reorderBoardTasks(boardId, moves);
      }

      // 7. Adds.
      for (const cell of cells) {
        if (cell.originalTaskId === null) {
          await addBoardTaskToBoard(boardId, cell.taskId, cell.row, cell.col, {
            isLocked: cell.isLocked,
          });
        }
      }

      // 8. Locks on pre-existing cells — after moves (see doc above).
      for (const cell of cells) {
        if (cell.originalTaskId !== null && !cell.originalLocked && cell.isLocked) {
          await setBoardTaskLocked(cell.cellId, true);
        }
      }

      // 9. Center metadata patch.
      if (centerPatch) {
        await updateBoardAndCascade(boardId, centerPatch);
      }
    },
  );
}
