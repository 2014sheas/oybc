import {
  CenterSquareType,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { taskToSquareState, type SquareWindowContext } from '../../db/adapters';

/**
 * One rendered cell of a board mini-preview, row-major over `size*size`.
 *
 * - `task` — a real placed square; `completed` is the SAME derivation the
 *   play surface uses (windowed events / compound evaluation / sealed
 *   snapshot / derived-counter lifetime cache — see `buildBoardPreviewCells`).
 * - `freeCenter` — the odd-board FREE/CUSTOM_FREE center; always renders
 *   "filled" on the real grid, same as `BoardPlaySurface`'s static FREE cell.
 * - `empty` — no BoardTask placed at this position.
 */
export type BoardPreviewCell =
  | { kind: 'task'; completed: boolean }
  | { kind: 'freeCenter' }
  | { kind: 'empty' };

export interface BoardPreviewCellsResult {
  /** Grid edge length (`board.boardSize`). */
  size: number;
  /** Row-major, length `size * size`. */
  cells: BoardPreviewCell[];
}

/**
 * Builds the TRUE mini-preview grid for a board: real `boardSize`, real
 * `BoardTask.row/col` placement, real per-cell completion — using the exact
 * same derivation `BoardPlaySurface` uses for the live play grid, so a
 * preview can never show a state the real board doesn't have.
 *
 * Mirrors `apps/ios/OYBC/Helpers/BoardPreviewCells.swift` — keep both in
 * lockstep; see BoardPlaySurface.tsx's grid-render loop (~line 539) and
 * BoardPlayView.swift's `risoPlaySquare` for the canonical derivation this
 * is factored out of.
 *
 * Rules (must match the play surface, not reinvented here):
 * - **Sealed board** (`board.sealedAt != null`): a placed cell's completion
 *   comes straight from `board.sealedCompletedCells` (indexes are
 *   `row*size+col`) — never from live event derivation.
 * - **Live board**: completion comes from `taskToSquareState`, the same
 *   function the play grid calls — it already implements the compound /
 *   derived-counter-lifetime-carve-out / windowed-event / achievement
 *   branch order, so this function does not re-derive any of that.
 * - **FREE / CUSTOM_FREE center** on an odd board with no task placed there
 *   renders `freeCenter` — the auto-completed center square.
 * - Any other unplaced position renders `empty`.
 *
 * @param board - The resolved board being previewed.
 * @param boardTasks - This board's BoardTask placements (any scope — extra rows for other boards are ignored via `boardId` filtering by the caller).
 * @param taskMap - Workspace task lookup, id → Task (same shape `useTaskLibrary` produces).
 * @param childrenByCompound - Workspace compound-children lookup, keyed by parent compound task id.
 * @param eventsByTaskId - Non-deleted TaskEvents grouped by taskId (same shape `buildSquareWindowContext` produces).
 */
export function buildBoardPreviewCells(
  board: Board,
  boardTasks: BoardTask[],
  taskMap: Record<string, Task>,
  childrenByCompound: Record<string, CompoundChild[]>,
  eventsByTaskId: Record<string, TaskEvent[]>,
): BoardPreviewCellsResult {
  const size = board.boardSize;
  const isSealed = board.sealedAt != null;
  const sealedCellSet = new Set<number>(isSealed ? (board.sealedCompletedCells ?? []) : []);
  const windowContext: SquareWindowContext = { windowStart: board.startDate, eventsByTaskId };

  const btByPosition: Record<string, BoardTask> = {};
  for (const bt of boardTasks) {
    if (bt.boardId !== board.id) continue;
    btByPosition[`${bt.row}-${bt.col}`] = bt;
  }

  const hasFreeCenter =
    size % 2 === 1 &&
    (board.centerSquareType === CenterSquareType.FREE ||
      board.centerSquareType === CenterSquareType.CUSTOM_FREE);
  const centerRow = Math.floor(size / 2);
  const centerCol = Math.floor(size / 2);

  const cells: BoardPreviewCell[] = [];
  for (let row = 0; row < size; row++) {
    for (let col = 0; col < size; col++) {
      const bt = btByPosition[`${row}-${col}`];
      if (!bt) {
        const isCenter = size % 2 === 1 && row === centerRow && col === centerCol;
        cells.push(isCenter && hasFreeCenter ? { kind: 'freeCenter' } : { kind: 'empty' });
        continue;
      }

      const task = taskMap[bt.taskId];
      if (!task) {
        cells.push({ kind: 'empty' });
        continue;
      }

      const taskChildren = childrenByCompound[task.id] ?? [];
      const squareState = taskToSquareState(task, taskChildren, taskMap, childrenByCompound, windowContext);
      const cellIndex = row * size + col;
      const completed = isSealed ? sealedCellSet.has(cellIndex) : squareState.isCompleted;
      cells.push({ kind: 'task', completed });
    }
  }

  return { size, cells };
}
