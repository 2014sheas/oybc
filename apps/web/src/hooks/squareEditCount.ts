import { CenterSquareType, type BoardTask } from '@oybc/shared';
import type { SquareDraftCell } from './useBoardPlay';

export interface SquareEditCountInput {
  squaresDraft: SquareDraftCell[];
  /** Staged global task-field overrides, keyed by taskId. */
  taskOverrides: ReadonlyMap<string, unknown>;
  draftCenterType: CenterSquareType;
  /** Live placements at the time of counting (staged removals are those absent from the draft). */
  boardTasks: BoardTask[];
  editMode: boolean;
  draftSeeded: boolean;
}

/**
 * Whether a staged cell differs from what was seeded on edit-mode entry —
 * the gold "dirty" chip on the square. A replace, a task-field override, a
 * position change, or a lock toggle each make a cell dirty; reverting it
 * clears the chip (the count is derived, never accumulated).
 */
export function isDraftCellDirty(cell: SquareDraftCell, taskOverrides: ReadonlyMap<string, unknown>): boolean {
  return (
    cell.taskId !== cell.originalTaskId ||
    taskOverrides.has(cell.taskId) ||
    cell.row !== cell.originalRow ||
    cell.col !== cell.originalCol ||
    cell.isLocked !== cell.originalLocked
  );
}

/**
 * Count of staged square edits — DERIVED from draft state (not an action
 * counter) so reverting a cell to its original state un-counts it (no phantom
 * edits / no "Board saved" for a net-zero session). Mirrors iOS
 * `editSquaresEditCount`. Terms: replacements + task-field overrides + moved
 * cells (a pinned FREE/CHOSEN center excluded; a NONE center is a regular
 * movable cell) + lock toggles + staged removals. Removals are gated on
 * `editMode && draftSeeded` (NOT `squaresDraft.length > 0`) so the un-seeded
 * first render doesn't count every placement as removed while a legitimately
 * empty draft (user removed every square) still counts.
 */
export function deriveSquareEditCount(input: SquareEditCountInput): number {
  const { squaresDraft, taskOverrides, draftCenterType, boardTasks, editMode, draftSeeded } = input;
  const draftBoardTaskIds = new Set(squaresDraft.map((c) => c.boardTaskId));
  const stagedRemovalCount =
    editMode && draftSeeded ? boardTasks.filter((bt) => !draftBoardTaskIds.has(bt.id)).length : 0;
  return (
    squaresDraft.filter((c) => c.taskId !== c.originalTaskId).length +
    taskOverrides.size +
    squaresDraft.filter(
      (c) =>
        !(c.isCenter && draftCenterType !== CenterSquareType.NONE) &&
        (c.row !== c.originalRow || c.col !== c.originalCol),
    ).length +
    squaresDraft.filter((c) => c.isLocked !== c.originalLocked).length +
    stagedRemovalCount
  );
}
