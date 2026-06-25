import styles from './SignedOut.module.css';

/**
 * Decorative poster-board art for the signed-out home — static, non-interactive
 * bingo grids that carry the "earned escalation" story (mid-game hero, the
 * three escalation beats, the modal's all-red mini). Pure CSS/markup, no data.
 */

// Hero board: a mid-game state — fuller fill, two blue, the middle row glows gold.
const HERO_RED = new Set([0, 1, 3, 6, 8, 10, 11, 13, 14, 15, 18, 20, 22, 23]);
const HERO_BLUE = new Set([2, 17]);
const HERO_LINE = new Set([10, 11, 12, 13, 14]);

/** The rotated 5×5 hero poster board. */
export function HeroBoard(): React.ReactElement {
  return (
    <div className={styles.soBoard}>
      <div className={styles.soGrid}>
        {Array.from({ length: 25 }).map((_, i) => {
          if (i === 12) {
            return <div key={i} className={`${styles.soCell} ${styles.free} ${styles.line}`} />;
          }
          const fill = HERO_RED.has(i) ? styles.red : HERO_BLUE.has(i) ? styles.blue : '';
          const line = HERO_LINE.has(i) ? styles.line : '';
          return <div key={i} className={[styles.soCell, fill, line].filter(Boolean).join(' ')} />;
        })}
      </div>
    </div>
  );
}

/** Escalation state for a "how it works" beat mini-board. */
export type BeatState = 'partial' | 'bingo' | 'full';

const BEAT_FILL: Record<BeatState, { red: Set<number> | 'all'; line: Set<number> }> = {
  partial: { red: new Set([1, 3, 6, 8, 11, 16, 18, 21]), line: new Set() },
  bingo: { red: new Set([1, 3, 6, 8, 10, 11, 13, 14, 16, 18, 21, 23]), line: new Set([10, 11, 12, 13, 14]) },
  full: { red: 'all', line: new Set() },
};

/** A 5×5 mini board illustrating one escalation beat (partial → bingo → full). */
export function BeatMini({ state }: { state: BeatState }): React.ReactElement {
  const { red, line } = BEAT_FILL[state];
  return (
    <div className={styles.soBeatMini}>
      {Array.from({ length: 25 }).map((_, i) => {
        if (i === 12) return <i key={i} className={styles.free} />;
        const isRed = red === 'all' || red.has(i);
        return <i key={i} className={[isRed ? styles.red : '', line.has(i) ? styles.line : ''].filter(Boolean).join(' ')} />;
      })}
    </div>
  );
}

/** The small all-red mini board shown at the top of the sign-in modal. */
export function ModalArt(): React.ReactElement {
  return (
    <div className={styles.soAuthArt}>
      <div className={styles.soGrid}>
        {Array.from({ length: 25 }).map((_, i) => (
          <div key={i} className={`${styles.soCell} ${i === 12 ? styles.free : styles.red}`} />
        ))}
      </div>
    </div>
  );
}
