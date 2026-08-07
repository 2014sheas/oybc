import { BoardStatus, type Board } from '@oybc/shared';
import type { BoardPreviewCellsResult } from './boardPreviewCells';
import styles from './Home.module.css';

export interface BoardMiniGridProps {
  board: Board;
  /**
   * The board's TRUE preview cells (`buildBoardPreviewCells`), pre-computed
   * by the list-owning page via `useBoardsPreviewCells` — ONE hook mount per
   * page, not per card (bugfix/board-preview-real-cells perf follow-up: a
   * self-loading `useBoardPreviewCells` per card used to re-run full-table
   * live queries × N cards). Required — there is no self-loading fallback;
   * callers own the hoist.
   */
  previewCells: BoardPreviewCellsResult;
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
 * `BoardPlaySurface` uses for the live play grid). Purely presentational —
 * `previewCells` is computed by the caller (see `useBoardsPreviewCells`).
 * The FREE center renders inked; every other placed square
 * fills (red, or green when the board is cleared) once its own completion
 * is true.
 */
export function BoardMiniGrid({ board, previewCells, cell, gap = 2.5, framed = false }: BoardMiniGridProps): React.ReactElement {
  const isComplete = board.status === BoardStatus.COMPLETED || board.status === BoardStatus.ARCHIVED;
  const { size, cells } = previewCells;

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
