import {
  CenterSquareType,
  Timeframe,
  formatTimeframeLabel,
  type Board,
  type BoardSize,
} from '@oybc/shared';
import { useSourceBoards, useSourceBoardPlacements } from '../../hooks';
import { BoardThumbnail, type ThumbnailCellState } from './BoardThumbnail';
import styles from './FromBoardPicker.module.css';

interface FromBoardPickerProps {
  userId: string;
  /** Called when the user taps a card to drill into that board's grid. */
  onPickBoard: (boardId: string) => void;
}

/**
 * Source-board picker for the wizard's `From a board…` filter chip.
 * Renders a vertical list of eligible boards (active + completed
 * within 30 days) as cards with a tiny grid thumbnail + metadata.
 *
 * Each card mounts its own `useSourceBoardPlacements` query for its
 * thumbnail. At typical user scale (single-digit to tens of boards)
 * this is fine; the live queries are independent and cheap. If usage
 * grows past that, the picker can be refactored to a single combined
 * query at the parent.
 *
 * Tapping a card calls `onPickBoard(board.id)` — the parent (Tasks
 * step) swaps the list region to render the grid for that board.
 */
export function FromBoardPicker({
  userId,
  onPickBoard,
}: FromBoardPickerProps): React.ReactElement {
  const boards = useSourceBoards(userId);

  if (boards.length === 0) {
    return (
      <div className={styles.empty}>
        No boards to browse. Create another board first, or build this one
        from scratch.
      </div>
    );
  }

  return (
    <div className={styles.pickerHeader}>
      <div className={styles.headline}>Pick a board to browse</div>
      <ul className={styles.list}>
        {boards.map((board) => (
          <li key={board.id}>
            <SourceBoardCard board={board} onClick={() => onPickBoard(board.id)} />
          </li>
        ))}
      </ul>
    </div>
  );
}

function SourceBoardCard({
  board,
  onClick,
}: {
  board: Board;
  onClick: () => void;
}): React.ReactElement {
  const placements = useSourceBoardPlacements(board.id);
  const cellStates = computeCellStates(board, placements);
  const completed = countCompleted(placements);
  const total = board.boardSize * board.boardSize;
  const windowLabel = formatTimeframeLabel(
    board.timeframe as Timeframe,
    board.startDate,
  );

  return (
    <button type="button" className={styles.card} onClick={onClick}>
      <BoardThumbnail
        gridSize={board.boardSize as 3 | 4 | 5}
        cellStates={cellStates}
        pixelSize={56}
      />
      <div className={styles.cardBody}>
        <div className={styles.cardTitle}>{board.name || 'Untitled board'}</div>
        <div className={styles.cardMeta}>
          {capitalize(board.timeframe)} · {board.boardSize}×{board.boardSize} ·{' '}
          {windowLabel}
        </div>
        <div className={styles.cardCompletion}>
          {completed} / {total} complete
        </div>
      </div>
      <span className={styles.cardChevron} aria-hidden="true">
        ›
      </span>
    </button>
  );
}

/** Row-major cell-state list sized to gridSize². Cells without a
 *  placement render as `empty`. */
function computeCellStates(
  board: Board,
  placements: ReturnType<typeof useSourceBoardPlacements>,
): ThumbnailCellState[] {
  const size = board.boardSize;
  const states: ThumbnailCellState[] = Array(size * size).fill('empty');
  const usesChosenCenter =
    board.centerSquareType === CenterSquareType.CHOSEN ||
    board.centerSquareType === CenterSquareType.FREE;
  const centerIndex =
    size % 2 === 1 && usesChosenCenter
      ? Math.floor(size / 2) * size + Math.floor(size / 2)
      : -1;

  for (const { placement, task } of placements) {
    const idx = placement.row * size + placement.col;
    if (idx < 0 || idx >= states.length) continue;
    if (placement.isCenter || idx === centerIndex) {
      states[idx] = 'center';
    } else if (task?.isCompleted) {
      states[idx] = 'done';
    } else {
      states[idx] = 'pending';
    }
  }
  if (centerIndex >= 0 && states[centerIndex] === 'empty') {
    states[centerIndex] = 'center';
  }
  return states;
}

function countCompleted(
  placements: ReturnType<typeof useSourceBoardPlacements>,
): number {
  let n = 0;
  for (const { task } of placements) {
    if (task?.isCompleted) n += 1;
  }
  return n;
}

function capitalize(s: string): string {
  if (!s) return s;
  return s.charAt(0).toUpperCase() + s.slice(1);
}

/** Re-export for callers (the parent step keys off the BoardSize union). */
export type { BoardSize };
