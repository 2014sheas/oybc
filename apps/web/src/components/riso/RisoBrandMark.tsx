import styles from './RisoBrandMark.module.css';

/** Cell pattern: 1 = cream dot, 0 = faint, 2 = gold center (the FREE star). */
const PATTERN = [1, 0, 1, 0, 2, 0, 1, 0, 1] as const;

export interface RisoBrandMarkProps {
  /** Pixel size of the square mark. Defaults to 40. */
  size?: number;
}

/**
 * The OYBC brand mark — a 3×3 bingo-grid logo (red tile, cream dots, gold
 * center). Rendered in markup, no raster asset. Mascot-agnostic per the Riso
 * non-negotiables. Reused across the signed-out nav/footer and (later) the
 * app shell.
 */
export function RisoBrandMark({ size = 40 }: RisoBrandMarkProps): React.ReactElement {
  return (
    <div
      className={styles.mark}
      style={{ ['--mark-size' as string]: `${size}px` }}
      aria-label="OYBC"
      role="img"
    >
      {PATTERN.map((v, i) => (
        <i key={i} className={v === 2 ? styles.free : v === 1 ? styles.on : ''} />
      ))}
    </div>
  );
}
