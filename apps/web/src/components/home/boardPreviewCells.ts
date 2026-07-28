import {
  CenterSquareType,
  computeBoardGrid,
  resolvePlacements,
  type Board,
  type BoardTask,
  type CellState,
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
 * Board-integrity PR-3 (issue #360) — the ACHIEVEMENT branch of
 * `taskToSquareState` needs the kernel's per-cell resolution (it has no
 * cross-board context of its own). This function runs `computeBoardGrid`
 * ONCE per board (over just this board's own placements) to get that
 * resolution, then threads each cell's `CellState` through
 * `taskToSquareState` exactly like `BoardPlaySurface`'s live grid does —
 * closing this preview's inherited copy of the same web achievement-render
 * gap (docs/BOARD_INTEGRITY.md finding 2).
 *
 * @param board - The resolved board being previewed.
 * @param boardTasks - This board's BoardTask placements (any scope — extra rows for other boards are ignored via `boardId` filtering by the caller).
 * @param taskMap - Workspace task lookup, id → Task (same shape `useTaskLibrary` produces).
 * @param childrenByCompound - Workspace compound-children lookup, keyed by parent compound task id.
 * @param eventsByTaskId - Non-deleted TaskEvents grouped by taskId (same shape `buildSquareWindowContext` produces).
 * @param allBoards - All non-deleted boards in the workspace (cross-board
 *   context for ACHIEVEMENT-typed Tasks — NOT just the boards being
 *   previewed on this page, since an achievement can watch a board outside
 *   the current list/rail). Pass `[]` when unavailable; achievement cells
 *   then degrade to "incomplete", matching the missing-reference semantic.
 */
export function buildBoardPreviewCells(
  board: Board,
  boardTasks: BoardTask[],
  taskMap: Record<string, Task>,
  childrenByCompound: Record<string, CompoundChild[]>,
  eventsByTaskId: Record<string, TaskEvent[]>,
  allBoards: Board[] = [],
): BoardPreviewCellsResult {
  const size = board.boardSize;
  const isSealed = board.sealedAt != null;
  const sealedCellSet = new Set<number>(isSealed ? (board.sealedCompletedCells ?? []) : []);
  const windowContext: SquareWindowContext = { windowStart: board.startDate, eventsByTaskId };

  const btByPosition: Record<string, BoardTask> = {};
  // Resolve through the PR-2 winner rule (matches the iOS twin + every other
  // render surface) so an un-repaired legacy duplicate placement can't make
  // the preview pick a different, order-dependent "winner" than the grid.
  const boardTasksOnBoard: BoardTask[] = resolvePlacements(
    boardTasks.filter((bt) => bt.boardId === board.id),
    size,
  );
  for (const bt of boardTasksOnBoard) {
    btByPosition[`${bt.row}-${bt.col}`] = bt;
  }

  // Kernel pass — only consulted for the ACHIEVEMENT branch below (every
  // other cell resolves through taskToSquareState exactly as before this
  // widening; `grid`/`completedTasks` here are unused).
  const cellStateByBoardTaskId: Record<string, CellState> = {};
  for (const c of computeBoardGrid(
    board,
    boardTasksOnBoard,
    childrenByCompound,
    taskMap,
    allBoards,
    { eventsByTaskId },
  ).cells) {
    cellStateByBoardTaskId[c.boardTaskId] = c;
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
      const squareState = taskToSquareState(
        task, taskChildren, taskMap, childrenByCompound, windowContext,
        cellStateByBoardTaskId[bt.id],
      );
      const cellIndex = row * size + col;
      const completed = isSealed ? sealedCellSet.has(cellIndex) : squareState.isCompleted;
      cells.push({ kind: 'task', completed });
    }
  }

  return { size, cells };
}
