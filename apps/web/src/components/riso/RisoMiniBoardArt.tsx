import styles from './RisoMiniBoardArt.module.css';

export interface RisoMiniBoardArtProps {
  /** Per-cell pixel size. Defaults to the handoff's 26px. */
  cellSize?: number;
}

/**
 * Mini bingo-board motif — the Boards empty-state art and web twin of iOS
 * `RisoMiniBoardArt` (Blip-retirement handoff, 2026-09-10; the web spec
 * covers the framed 3×3 `.empty` state only — iOS carries the full state
 * machine for its eight surfaces). Cells pop in via `risoCellPop`
 * (staggered 55ms, FREE center last), gated by `prefers-reduced-motion`.
 */
export function RisoMiniBoardArt({ cellSize = 26 }: RisoMiniBoardArtProps): React.ReactElement {
  const free = 4; // 3×3 center
  return (
    <div
      className={styles.art}
      style={{ ['--art-cell' as string]: `${cellSize}px` }}
      aria-hidden="true"
    >
      {Array.from({ length: 9 }, (_, i) => (
        <i
          key={i}
          className={i === free ? `${styles.cell} ${styles.free}` : styles.cell}
          // FREE pops last (reading order otherwise).
          style={{ ['--i' as string]: i === free ? 8 : i > free ? i - 1 : i }}
        >
          {i === free && (
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M12 2l2.9 6.3 6.9.8-5.1 4.7 1.4 6.8L12 17l-6.1 3.6 1.4-6.8L2.2 9.1l6.9-.8L12 2z" />
            </svg>
          )}
        </i>
      ))}
    </div>
  );
}
