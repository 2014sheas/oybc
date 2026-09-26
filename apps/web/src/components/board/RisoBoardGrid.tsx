import styles from './RisoBoard.module.css';

export interface RisoBoardGridProps {
  /** Grid side length (3 / 4 / 5). */
  size: number;
  /** Edge of each cell in px. When omitted the cells share the width (`1fr`). */
  cellSize?: number;
  /** Gap between cells in px. Defaults to 8. */
  gap?: number;
  /** Extra class names for the frame (e.g. the play surface's sealed treatment). */
  className?: string;
  /** Exactly `size × size` cells in row-major order. */
  children: React.ReactNode;
}

/**
 * The Riso board frame + grid layout, with no data fetching — the ONE layout
 * every board surface draws through (Board Edit redesign slice 1): the
 * Home poster (`RisoBoard`), the play surface, and the Playground. Cell
 * text scales with `--cell-size`.
 */
export function RisoBoardGrid({ size, cellSize, gap = 8, className, children }: RisoBoardGridProps): React.ReactElement {
  return (
    <div
      className={className ? `${styles.board} ${className}` : styles.board}
      style={{
        gridTemplateColumns: `repeat(${size}, ${cellSize != null ? `${cellSize}px` : '1fr'})`,
        gap,
        ...(cellSize != null ? { ['--cell-size' as string]: `${cellSize}px` } : {}),
      }}
    >
      {children}
    </div>
  );
}
