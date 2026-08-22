import {
  TaskType,
  computeBoardGrid,
  detectBingos,
  getHighlightedSquares,
  getCenterSquareIndex,
  isCenterAutoCompleted,
  getCenterDisplayText,
  resolvePlacements,
  type Board,
  type BoardTask,
  type CellState,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { taskToSquareState, type SquareWindowContext } from '../../db/adapters';
import type { BoardCellModel, CellType } from './RisoBoardCell';

function cellType(t: TaskType): CellType {
  if (t === TaskType.COUNTING) return 'counting';
  if (t === TaskType.COMPOUND) return 'compound';
  return 'normal';
}

/**
 * Pure cell derivation for the `RisoBoard` poster — firebase-free (imports
 * only `@oybc/shared` + the pure adapters) so it is unit-testable without the
 * Firebase config that `RisoBoard`'s hooks transitively initialize (the same
 * split rationale as `buildArrivalSquares`). Exported for
 * `__tests__/buildRisoBoardCells.test.ts` (issue #376).
 *
 * Windowed Completion: a LIVE board resolves each cell against its window via
 * `taskToSquareState`; a SEALED board is a frozen historical record — cells
 * read the `sealedCompletedCells` snapshot and rings the frozen
 * `completedLineIds`, never live event derivation — mirroring
 * `BoardPlaySurface` / `buildBoardPreviewCells`. Sealing is orthogonal to
 * status, so a sealed-but-ACTIVE board can reach this poster via Home.
 */
export function buildRisoBoardCells(
  board: Board,
  boardTasks: BoardTask[],
  taskMap: Record<string, Task>,
  compoundChildrenByCompound: Record<string, CompoundChild[]>,
  squareWindowContext: SquareWindowContext,
  allBoards: Board[] = [],
): BoardCellModel[] {
  const size = board.boardSize;
  const isSealed = board.sealedAt != null;
  const sealedCellSet = new Set(isSealed ? (board.sealedCompletedCells ?? []) : []);

  // Resolve through the PR-2 winner rule (matches every other render surface)
  // so a legacy duplicate placement can't pick a different winner than the grid.
  const boardTasksOnBoard = resolvePlacements(
    boardTasks.filter((bt) => bt.boardId === board.id),
    size,
  );
  const byPos = new Map<number, BoardTask>();
  for (const bt of boardTasksOnBoard) byPos.set(bt.row * size + bt.col, bt);

  // Kernel pass — the ONLY source of an ACHIEVEMENT square's completion
  // (board-integrity PR-3 #360, finding 2). Without threading the resolved
  // per-cell state into `taskToSquareState`, achievement squares fall through
  // to the plain-task branch and always read `false` (this poster's bug).
  const cellStateByBoardTaskId: Record<string, CellState> = {};
  for (const c of computeBoardGrid(
    board,
    boardTasksOnBoard,
    compoundChildrenByCompound,
    taskMap,
    allBoards,
    { eventsByTaskId: squareWindowContext.eventsByTaskId },
  ).cells) {
    cellStateByBoardTaskId[c.boardTaskId] = c;
  }

  const centerIndex = getCenterSquareIndex(size);
  const freeCenter = centerIndex >= 0 && isCenterAutoCompleted(board.centerSquareType);

  // First pass: resolve done + view-model (without bingo lines).
  const draft = Array.from({ length: size * size }, (_, i): BoardCellModel & { _done: boolean } => {
    if (i === centerIndex && freeCenter) {
      return {
        key: `free-${i}`,
        label: getCenterDisplayText(board.centerSquareType) || 'FREE',
        type: 'normal',
        done: true,
        isFree: true,
        isLine: false,
        _done: true,
      };
    }
    const bt = byPos.get(i);
    const task = bt ? taskMap[bt.taskId] : undefined;
    if (!bt || !task) {
      return { key: bt?.id ?? `empty-${i}`, label: '', type: 'normal', done: false, isFree: false, isLine: false, _done: false };
    }
    const ss = taskToSquareState(
      task, undefined, taskMap, compoundChildrenByCompound, squareWindowContext,
      cellStateByBoardTaskId[bt.id],
    );
    const type = cellType(task.type);
    // Sealed: `done` comes from the frozen snapshot, not live derivation —
    // and the counting display freezes too (post-seal increments on a shared
    // task must not animate a frozen poster). Mirrors BoardPlaySurface's
    // `taskCurrentCount = isSealed ? (done ? maxCount : 0) : live`.
    const done = isSealed ? sealedCellSet.has(i) : ss.isCompleted;
    const cur = isSealed ? (done ? (task.maxCount ?? 0) : 0) : ss.currentCount;
    return {
      key: bt.id,
      label: task.title ?? '',
      type,
      done,
      count: type === 'counting' ? { cur, max: task.maxCount ?? 0 } : undefined,
      isFree: false,
      isLine: false,
      _done: done,
    };
  });

  // Second pass: gold-ring the cells in completed bingo lines. A sealed
  // board keeps its frozen `completedLineIds` snapshot (mirrors
  // BoardPlaySurface's ring-coherence rule).
  const completion = draft.map((c) => c._done);
  const lines = isSealed
    ? (board.completedLineIds ?? [])
    : detectBingos(completion, size).completedLines;
  const highlighted = getHighlightedSquares(lines, size);

  return draft.map(({ _done, ...cell }, i) => ({ ...cell, isLine: highlighted.has(i) }));
}
