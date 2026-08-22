import { useMemo } from 'react';
import type { Board, BoardTask } from '@oybc/shared';
import { useAuth } from '../../firebase/useAuth';
import { useBoards } from '../../hooks/useBoards';
import { useBoardTasks } from '../../hooks/useBoardTasks';
import { useSquareWindowContext } from '../../hooks/useSquareWindowContext';
import { useTaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { buildRisoBoardCells } from './risoBoardCells';
import { RisoBoardCell, type BoardCellModel } from './RisoBoardCell';
import styles from './RisoBoard.module.css';

/** Stable empty array so the cell `useMemo` isn't invalidated every render. */
const EMPTY_BOARD_TASKS: BoardTask[] = [];

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
  // ACHIEVEMENT squares resolve via the kernel's cross-board pass, so the
  // poster needs the workspace board list (board-integrity PR-3 #360).
  const allBoards = useBoards(user?.id);
  // Windowed Completion (docs/WINDOWED_COMPLETION.md §Task caches): this poster
  // must resolve squares against THIS board's window, not tasks' lifetime
  // completion caches — otherwise a spawned/reused board shows lifetime-complete
  // tasks green (+ phantom bingo rings) even though the real grid is grey.
  const squareWindowContext = useSquareWindowContext(board);

  // Use the canonical boardSize — NOT sqrt(totalTasks), which can diverge from
  // the true grid under a sync race and would mis-place cells.
  const size = board.boardSize;

  const cells = useMemo<BoardCellModel[]>(
    () => buildRisoBoardCells(board, boardTasks, taskMap, compoundChildrenByCompound, squareWindowContext, allBoards),
    [board, boardTasks, taskMap, compoundChildrenByCompound, squareWindowContext, allBoards],
  );

  return (
    <div
      className={styles.board}
      style={{
        gridTemplateColumns: `repeat(${size}, ${cellSize}px)`,
        gap,
        // Cell text scales with cell size (fixes name overflow on the small
        // Home poster, ~58px) instead of a fixed 14px regardless of cellSize.
        ['--cell-size' as string]: `${cellSize}px`,
      }}
    >
      {cells.map((cell) => (
        <RisoBoardCell key={cell.key} cell={cell} />
      ))}
    </div>
  );
}
