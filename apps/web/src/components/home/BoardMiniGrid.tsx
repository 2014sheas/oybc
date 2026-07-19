import { BoardStatus, type Board } from '@oybc/shared';
import { useBoardPreviewCells } from '../../hooks/useBoardPreviewCells';
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
 * A board mini-grid — the TRUE board: real `boardSize`, real
 * `BoardTask.row/col` placement, real per-cell completion (same derivation
 * `BoardPlaySurface` uses for the live play grid, via
 * `useBoardPreviewCells`/`buildBoardPreviewCells`). The FREE/CUSTOM_FREE
 * center renders inked; every other placed square fills (red, or green when
 * the board is cleared) once its own completion is true.
 */
export function BoardMiniGrid({ board, cell, gap = 2.5, framed = false }: BoardMiniGridProps): React.ReactElement {
  const isComplete = board.status === BoardStatus.COMPLETED || board.status === BoardStatus.ARCHIVED;
  const { size, cells } = useBoardPreviewCells(board);

  const grid = (
    <div
      className={`${styles.mini} ${isComplete ? styles.miniGreen : ''}`}
      style={{ gridTemplateColumns: `repeat(${size}, ${cell}px)`, gap }}
      aria-hidden="true"
    >
      {cells.map((c, i) => (
        <i
          key={i}
          className={`${styles.miniCell} ${
            c.kind === 'freeCenter' ? styles.free : c.kind === 'task' && c.completed ? styles.on : ''
          }`}
        />
      ))}
    </div>
  );

  if (!framed) return grid;
  return <div className={styles.poster}>{grid}</div>;
}
