import { BoardStatus, Timeframe, formatTimeframeLabel } from '@oybc/shared';
import { BoardListItem } from '../../components/BoardListItem';
import type { WindowCell } from './useCoreBoardBrowser';
import styles from './CoreBoardBrowserPage.module.css';

export interface CoreBoardWindowCellProps {
  cell: WindowCell;
  timeframe: Timeframe;
  /** Fires when the user taps a Filled cell. Receives the matched board's id. */
  onOpenBoard: (boardId: string) => void;
  /** Fires when the user taps an Empty cell. Receives the window's
   *  start date (Date object — already a local-time date the wizard
   *  can use directly) and the timeframe. */
  onCreate: (windowStart: Date, timeframe: Timeframe) => void;
  /** Delete callback for the Filled cell. Forwarded to BoardListItem so
   *  the trailing ✕ behaves identically to the Boards-tab list. */
  onDeleteBoard?: (boardId: string) => Promise<void> | void;
  /**
   * Called when the Filled cell's board is a DRAFT — routes to the wizard
   * resume flow instead of the play view. When omitted, draft cells fall
   * back to `onOpenBoard` (the catch-all in BoardPlayPage then intercepts).
   */
  onResumeDraft?: (boardId: string) => void;
}

/**
 * CoreBoardWindowCell — one row in the core-board browser. Two
 * visually consistent variants:
 *
 *   - **Filled** (cell.board != null): reuses `BoardListItem`, so the
 *     row looks identical to the Boards-tab list and tap behaviour
 *     matches what the user expects.
 *   - **Empty**: calendar icon + window label + "Create [label]"
 *     call-to-action. Past empty cells render with a `Past window`
 *     caption so the user knows they're backfilling, not planning
 *     forward.
 *
 * The current-window cell gets a subtle accent border via the wrapper
 * (`row` / `rowCurrent`). Past empty cells get a muted variant via
 * `cellEmptyPast`.
 */
export function CoreBoardWindowCell({
  cell,
  timeframe,
  onOpenBoard,
  onCreate,
  onDeleteBoard,
  onResumeDraft,
}: CoreBoardWindowCellProps): React.ReactElement {
  const isCurrent = cell.isCurrentWindow;
  const isFilled = cell.board !== null;
  const isPast = cell.isPastWindow;

  const rowClass = `${styles.row} ${isCurrent ? styles.rowCurrent : ''}`;

  if (isFilled && cell.board) {
    const board = cell.board;
    // Drafts never open as a playable board — route to the wizard resume
    // flow when onResumeDraft is provided; fall back to onOpenBoard when
    // not (the BoardPlayPage catch-all then intercepts the draft).
    const handleClick =
      board.status === BoardStatus.DRAFT && onResumeDraft
        ? () => onResumeDraft(board.id)
        : () => onOpenBoard(board.id);
    return (
      <div className={rowClass}>
        <div className={styles.rowMeta} aria-hidden="true">
          <span className={styles.windowLabel}>{cell.windowLabel}</span>
          {isCurrent && <span className={styles.currentBadge}>Current</span>}
        </div>
        <BoardListItem
          board={board}
          onClick={handleClick}
          onDelete={onDeleteBoard}
        />
      </div>
    );
  }

  // Empty variant
  const ctaClass = `${styles.emptyButton} ${isPast ? styles.emptyButtonPast : ''}`;
  const ariaLabel = isPast
    ? `Backfill ${formatTimeframeLabel(timeframe, cell.windowStart)}`
    : `Create board for ${formatTimeframeLabel(timeframe, cell.windowStart)}`;
  return (
    <div className={rowClass}>
      <div className={styles.rowMeta} aria-hidden="true">
        <span className={styles.windowLabel}>{cell.windowLabel}</span>
        {isCurrent && <span className={styles.currentBadge}>Current</span>}
        {isPast && <span className={styles.pastBadge}>Past window</span>}
      </div>
      <button
        type="button"
        className={ctaClass}
        onClick={() => onCreate(new Date(cell.windowStart), timeframe)}
        aria-label={ariaLabel}
      >
        <span className={styles.emptyIcon} aria-hidden="true">📅</span>
        <span className={styles.emptyLabel}>
          {isPast ? 'Backfill' : 'Create'} {cell.windowLabel}
        </span>
      </button>
    </div>
  );
}
