import { BoardStatus, CenterSquareType, type Board } from '@oybc/shared';
import styles from './Home.module.css';

export interface BoardMiniGridProps {
  board: Board;
  /** Cell edge in px (rail ≈ 9–11, poster ≈ 58). */
  cell: number;
  /** Gap between cells in px. Defaults to 2.5. */
  gap?: number;
  /** Render inside the bordered `.poster` frame (the resume panel). */
  framed?: boolean;
}

/**
 * A board mini-grid — a progress-accurate, decorative representation of a
 * board: an n×n grid with the FREE center inked and `completedTasks` cells
 * filled (red, or green when the board is cleared).
 *
 * NOTE: this is an *approximation* by count, not by true cell position — it
 * doesn't load the board's tasks. The real type-/done-aware board poster (with
 * counting bars, per-cell positions) arrives with the read-only board renderer
 * in Phase 3; the resume panel + rail will upgrade to it then. See docs/RISO_WEB.md.
 */
export function BoardMiniGrid({ board, cell, gap = 2.5, framed = false }: BoardMiniGridProps): React.ReactElement {
  const size = Math.max(1, Math.round(Math.sqrt(board.totalTasks)));
  const isComplete = board.status === BoardStatus.COMPLETED || board.status === BoardStatus.ARCHIVED;

  // Only an odd board with a FREE/CUSTOM_FREE center renders an inked center —
  // and that auto-completed center is already counted in `completedTasks`, so we
  // drop it from both the rendered grid AND the fill target. A CHOSEN/NONE
  // center is an ordinary cell (no special render, counted normally).
  const hasFreeCenter =
    size % 2 === 1 &&
    (board.centerSquareType === CenterSquareType.FREE ||
      board.centerSquareType === CenterSquareType.CUSTOM_FREE);
  const freeCenterIndex = hasFreeCenter ? Math.floor((size * size) / 2) : -1;
  const fillTarget = hasFreeCenter ? Math.max(0, board.completedTasks - 1) : board.completedTasks;

  // Fill the first `fillTarget` non-free cells. Computed purely (no mutation
  // during render): a cell's ordinal among non-free cells is its index, shifted
  // down by one once we're past the free-center slot.
  const cells = Array.from({ length: size * size }, (_, i) => {
    if (i === freeCenterIndex) return 'free' as const;
    const ordinal = freeCenterIndex >= 0 && i > freeCenterIndex ? i - 1 : i;
    return ordinal < fillTarget ? ('on' as const) : ('off' as const);
  });

  const grid = (
    <div
      className={`${styles.mini} ${isComplete ? styles.miniGreen : ''}`}
      style={{ gridTemplateColumns: `repeat(${size}, ${cell}px)`, gap }}
      aria-hidden="true"
    >
      {cells.map((state, i) => (
        <i key={i} className={`${styles.miniCell} ${state === 'on' ? styles.on : state === 'free' ? styles.free : ''}`} />
      ))}
    </div>
  );

  if (!framed) return grid;
  return <div className={styles.poster}>{grid}</div>;
}
