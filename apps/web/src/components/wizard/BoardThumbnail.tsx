import styles from './BoardThumbnail.module.css';

/**
 * Per-cell state shown by a {@link BoardThumbnail}. Conceptually:
 * 'done' = completed task, 'pending' = placed task not completed,
 * 'center' = the source board's center square (renders with a small
 * accent regardless of completion), 'empty' = no placement here.
 */
export type ThumbnailCellState = 'done' | 'pending' | 'center' | 'empty';

interface BoardThumbnailProps {
  /** 3, 4, or 5 — board geometry. */
  gridSize: 3 | 4 | 5;
  /** Cell states in row-major order. Length should equal `gridSize²`;
   *  extra entries are ignored, missing entries render as `empty`. */
  cellStates: ThumbnailCellState[];
  /** Pixel size of the entire square thumbnail (default 48). */
  pixelSize?: number;
}

/**
 * Tiny visual thumbnail of a board's grid — used by the wizard's
 * `From a board…` source picker to give the user a glanceable preview
 * of each candidate source. Pure presentational; no DB, no styling
 * that depends on the host context.
 *
 * Cells render as colored dots only — no titles. Recognition is
 * about "which board is the busy weekly one" / "the empty one I
 * never filled in", not about reading task names at thumbnail scale.
 *
 * Designed for future extraction: the same renderer could surface
 * in the Boards tab, the create hub, etc. without changes.
 */
export function BoardThumbnail({
  gridSize,
  cellStates,
  pixelSize = 48,
}: BoardThumbnailProps): React.ReactElement {
  const total = gridSize * gridSize;
  const cells: ThumbnailCellState[] = Array.from({ length: total }, (_, i) => {
    return cellStates[i] ?? 'empty';
  });

  return (
    <div
      className={styles.thumbnail}
      style={{
        width: pixelSize,
        height: pixelSize,
        gridTemplateColumns: `repeat(${gridSize}, 1fr)`,
        gridTemplateRows: `repeat(${gridSize}, 1fr)`,
      }}
      aria-hidden="true"
    >
      {cells.map((state, i) => (
        <span
          key={i}
          className={`${styles.cell} ${styles[state]}`}
        />
      ))}
    </div>
  );
}
