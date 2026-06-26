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
} from '@oybc/shared';
import { useAuth } from '../../firebase/useAuth';
import { useBoardTasks } from '../../hooks/useBoardTasks';
import { useTaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { taskToSquareState } from '../../db/adapters';
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
export function RisoBoard({ board, cellSize, gap = 8 }: RisoBoardProps): React.ReactElement {
  const { user } = useAuth();
  const boardTasks = useBoardTasks(board.id) ?? EMPTY_BOARD_TASKS;
  const { taskMap, compoundChildrenByCompound } = useTaskLibrary(user?.id);

  // Use the canonical boardSize — NOT sqrt(totalTasks), which can diverge from
  // the true grid under a sync race and would mis-place cells.
  const size = board.boardSize;

  const cells = useMemo<BoardCellModel[]>(() => {
    const byPos = new Map<number, (typeof boardTasks)[number]>();
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
      const ss = taskToSquareState(task, undefined, taskMap, compoundChildrenByCompound);
      const type = cellType(task.type);
      return {
        key: bt.id,
        label: task.title ?? '',
        type,
        done: ss.isCompleted,
        count: type === 'counting' ? { cur: ss.currentCount, max: task.maxCount ?? 0 } : undefined,
        isFree: false,
        isLine: false,
        _done: ss.isCompleted,
      };
    });

    // Second pass: gold-ring the cells in completed bingo lines.
    const completion = draft.map((c) => c._done);
    const lines = detectBingos(completion, size).completedLines;
    const highlighted = getHighlightedSquares(lines, size);

    return draft.map(({ _done, ...cell }, i) => ({ ...cell, isLine: highlighted.has(i) }));
  }, [boardTasks, taskMap, compoundChildrenByCompound, size, board.centerSquareType, board.centerSquareCustomName]);

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
