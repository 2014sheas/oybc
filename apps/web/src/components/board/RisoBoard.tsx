import { useMemo } from 'react';
import {
  TaskType,
  detectBingos,
  getHighlightedSquares,
  getCenterSquareIndex,
  isCenterAutoCompleted,
  getCenterDisplayText,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { useAuth } from '../../firebase/useAuth';
import { useBoardTasks } from '../../hooks/useBoardTasks';
import { useSquareWindowContext } from '../../hooks/useSquareWindowContext';
import { useTaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { taskToSquareState, type SquareWindowContext } from '../../db/adapters';
import { RisoBoardCell, type BoardCellModel, type CellType } from './RisoBoardCell';
import styles from './RisoBoard.module.css';

/** Stable empty array so the cell `useMemo` isn't invalidated every render. */
const EMPTY_BOARD_TASKS: BoardTask[] = [];

function cellType(t: TaskType): CellType {
  if (t === TaskType.COUNTING) return 'counting';
  if (t === TaskType.COMPOUND) return 'compound';
  return 'normal';
}

export interface RisoBoardProps {
  board: Board;
  /** Edge of each cell in px (poster ≈ 56). */
  cellSize: number;
  /** Gap between cells in px. Defaults to 8. */
  gap?: number;
}

/**
 * Read-only Riso board renderer — resolves a board's true cell grid (placed
 * tasks by position, completion via `taskToSquareState`, FREE center,
 * completed bingo lines) and renders it with `RisoBoardCell`. The accurate
 * poster used by the Home resume panel + (later) greenlog/share. Phase 3b adds
 * the interactive play variant on the same cell. See docs/RISO_WEB.md.
 */
/**
 * Pure cell derivation for the poster — exported for unit tests (issue #376).
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
): BoardCellModel[] {
  const size = board.boardSize;
  const isSealed = board.sealedAt != null;
  const sealedCellSet = new Set(isSealed ? (board.sealedCompletedCells ?? []) : []);

  const byPos = new Map<number, BoardTask>();
  for (const bt of boardTasks) byPos.set(bt.row * size + bt.col, bt);

  const centerIndex = getCenterSquareIndex(size);
  const freeCenter = centerIndex >= 0 && isCenterAutoCompleted(board.centerSquareType);

  // First pass: resolve done + view-model (without bingo lines).
  const draft = Array.from({ length: size * size }, (_, i): BoardCellModel & { _done: boolean } => {
    if (i === centerIndex && freeCenter) {
      return {
        key: `free-${i}`,
        label: getCenterDisplayText(board.centerSquareType, board.centerSquareCustomName) || 'FREE',
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
    const ss = taskToSquareState(task, undefined, taskMap, compoundChildrenByCompound, squareWindowContext);
    const type = cellType(task.type);
    // Sealed: `done` comes from the frozen snapshot, not live derivation.
    const done = isSealed ? sealedCellSet.has(i) : ss.isCompleted;
    return {
      key: bt.id,
      label: task.title ?? '',
      type,
      done,
      count: type === 'counting' ? { cur: ss.currentCount, max: task.maxCount ?? 0 } : undefined,
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

export function RisoBoard({ board, cellSize, gap = 8 }: RisoBoardProps): React.ReactElement {
  const { user } = useAuth();
  const boardTasks = useBoardTasks(board.id) ?? EMPTY_BOARD_TASKS;
  const { taskMap, compoundChildrenByCompound } = useTaskLibrary(user?.id);
  // Windowed Completion (docs/WINDOWED_COMPLETION.md §Task caches): this poster
  // must resolve squares against THIS board's window, not tasks' lifetime
  // completion caches — otherwise a spawned/reused board shows lifetime-complete
  // tasks green (+ phantom bingo rings) even though the real grid is grey.
  const squareWindowContext = useSquareWindowContext(board);

  // Use the canonical boardSize — NOT sqrt(totalTasks), which can diverge from
  // the true grid under a sync race and would mis-place cells.
  const size = board.boardSize;

  const cells = useMemo<BoardCellModel[]>(
    () => buildRisoBoardCells(board, boardTasks, taskMap, compoundChildrenByCompound, squareWindowContext),
    [board, boardTasks, taskMap, compoundChildrenByCompound, squareWindowContext],
  );

  return (
    <div
      className={styles.board}
      style={{ gridTemplateColumns: `repeat(${size}, ${cellSize}px)`, gap }}
    >
      {cells.map((cell) => (
        <RisoBoardCell key={cell.key} cell={cell} />
      ))}
    </div>
  );
}
