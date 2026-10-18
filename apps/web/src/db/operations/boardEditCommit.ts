import { db } from '../internal';
import { CenterSquareType, TaskType, isWholeCountKind, type Task } from '@oybc/shared';
import { assertBoardEditable, updateBoardAndCascade } from './boards';
import {
  addBoardTaskToBoard,
  normalizeLegacyChosenCenter,
  removeBoardTaskFromBoard,
  reorderBoardTasks,
  setBoardTaskLocked,
  updateBoardTaskAndCascade,
} from './boardTasks';
import { applyBoardEditTaskOverrideInTransaction } from './compoundStructureEdit';
import { ensureBoardScopedTask, stampForkCaches } from './boardScopedEdit';
import { assertCountsTowardStillValid } from './countsToward';
import { persistWizardPendingTasks } from './wizardBoard';
import { setPlacementParams } from './placementParams';
import { KindGoalError } from './countKindSwitch';
import { splitBoardEditOverride } from '../boardEditPlacementSplit';
import type { SquareDraftCell } from '../../hooks/squareEditCount';
import type { BoardEditTaskOverride } from '../../hooks/squaresEditReducer';
import { currentTimestamp } from '../utils';

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
  taskOverrides: Map<string, BoardEditTaskOverride>;
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
 *   4. (moved to 7b — see below.)
 *   5. Removals (`removeBoardTaskFromBoard`) — BEFORE moves/adds so freed
 *      positions are not occupied.
 *   5b. UNLOCKS on pre-existing cells (`setBoardTaskLocked(false)`) — BEFORE
 *      moves: `reorderBoardTasks` rejects moving a row that is locked ON
 *      DISK, so "Unlock → hold-drag → Save" in one session must clear the
 *      lock first (slice-3 self-review).
 *   6. Moves (`reorderBoardTasks`).
 *   7. Adds (`addBoardTaskToBoard`, with `isLocked` from the draft).
 *   7b. Task-field overrides, split by `splitBoardEditOverride`: goal / title /
 *       a compound child's goal go onto the PLACEMENT (`setPlacementParams`);
 *       the rest (`applyBoardEditTaskOverrideInTransaction` — a Simple⇄Counting
 *       type switch, or a compound edit / conversion that THROWS on invalid
 *       input so the whole Save rolls back) is BOARD-SCOPED: a task placed on
 *       any other board is forked first (`ensureBoardScopedTask`) and the edit
 *       lands on the fork.
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
          // A root picked with a goal: the parameters ride the replaced placement.
          if (cell.placement) await setPlacementParams(cell.cellId, cell.placement, currentTimestamp());
        }
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
            ...(cell.placement ? { placement: cell.placement } : {}),
          });
        }
      }

      // 7b. Task-field overrides — AFTER replacements and adds so each lands on
      //     the placed task. Each override splits (TASK_WINDOW_REWORK slice
      //     3a): PARAMETER fields (a counting goal, a title, an existing
      //     compound child's goal) are written onto this board's PLACEMENT
      //     (`setPlacementParams`) and never touch the task; every other field
      //     is BOARD-SCOPED — a task placed on any other board is forked first
      //     (`ensureBoardScopedTask`) and the edit lands on the fork.
      const now = currentTimestamp();
      // Only overrides for a task STILL placed by a final cell commit: a staged
      // edit on a removed / replaced square would otherwise be a destructive
      // conversion of a task that left the board.
      const placedStagedIds = new Set(cells.map((c) => c.taskId));
      for (const [taskId, patch] of taskOverrides.entries()) {
        if (!placedStagedIds.has(taskId)) continue;
        const stored = await db.tasks.get(taskId);
        if (!stored || stored.isDeleted) continue;
        const placement = await db.boardTasks
          .where('boardId')
          .equals(boardId)
          .filter((bt) => !bt.isDeleted && bt.taskId === taskId)
          .first();
        const links = (await db.compoundChildren.where('compoundTaskId').equals(taskId).toArray())
          .filter((l) => !l.isDeleted)
          .sort((a, b) => a.childIndex - b.childIndex);
        const childRows = await db.tasks.bulkGet(links.map((l) => l.childTaskId));
        const rootSettings = stored.sharedCounterId ? ((await db.tasks.get(stored.sharedCounterId)) ?? null) : null;
        const { params, rest } = splitBoardEditOverride({
          stored,
          placement,
          patch,
          storedChildren: childRows.filter((t): t is Task => !!t && !t.isDeleted),
          rootSettings,
        });
        // A typed goal the (new) whole kind refuses rolls the whole Save back.
        if (params.targetOverride != null && params.targetKind && isWholeCountKind(params.targetKind) && !Number.isInteger(params.targetOverride)) {
          throw new KindGoalError();
        }
        if (placement && Object.keys(params).length > 0) await setPlacementParams(placement.id, params, now);
        if (!rest) continue;
        const editedType = rest.compound ? TaskType.COMPOUND : (rest.type ?? patch.type ?? stored.type);
        const scoped = await ensureBoardScopedTask(taskId, boardId, editedType, now);
        await applyBoardEditTaskOverrideInTransaction(scoped.targetId, rest, now, { boardId });
        // An already-flagged compound whose sub-tasks changed: the structure
        // may not have closed a feeding loop (§3e) — refused, the Save rolls back.
        await assertCountsTowardStillValid(scoped.targetId);
        await stampForkCaches(scoped, now);
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
