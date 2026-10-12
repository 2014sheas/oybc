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
  /**
   * `'moment'` draws the Bingo / Greenlog moment's frame: static cream paper
   * with 11px padding in both themes (see `RisoBoard.module.css`).
   */
  frame?: 'default' | 'moment';
  /** Exactly `size × size` cells in row-major order. */
  children: React.ReactNode;
}

/**
 * The Riso board frame + grid layout, with no data fetching — the ONE layout
 * every board surface draws through (Board Edit redesign slice 1): the
 * Home poster (`RisoBoard`), the play surface, and the Playground. Cell
 * text scales with `--cell-size`.
 */
/** Frame padding (2 × 12) + border (2 × 2.5), in px. */
const FRAME_CHROME_PX = 29;
/** The moment frame's padding (2 × 11) + border (2 × 2.5), in px. */
const MOMENT_FRAME_CHROME_PX = 27;

export function RisoBoardGrid({ size, cellSize, gap = 8, className, frame = 'default', children }: RisoBoardGridProps): React.ReactElement {
  const chrome = frame === 'moment' ? MOMENT_FRAME_CHROME_PX : FRAME_CHROME_PX;
  const classes = [styles.board, frame === 'moment' ? styles.momentFrame : '', className ?? ''].filter(Boolean).join(' ');
  return (
    <div
      className={classes}
      style={
        cellSize != null
          ? {
              // Cells cap at `cellSize` but shrink with the frame (`minmax(0, …)`
              // + `width: min(100%, …)`), so a 5×5 never outgrows a phone
              // viewport. `--cell-size` follows the actual cell edge (the
              // frame is a size container, so `cqw` is its content width).
              gridTemplateColumns: `repeat(${size}, minmax(0, ${cellSize}px))`,
              width: `min(100%, ${size * cellSize + (size - 1) * gap + chrome}px)`,
              containerType: 'inline-size',
              gap,
              ['--cell-size' as string]: `min(${cellSize}px, calc((100cqw - ${(size - 1) * gap}px) / ${size}))`,
            }
          : { gridTemplateColumns: `repeat(${size}, 1fr)`, gap }
      }
    >
      {children}
    </div>
  );
}
