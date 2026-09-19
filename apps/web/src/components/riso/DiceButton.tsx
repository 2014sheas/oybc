import type { VaryLevel } from '@oybc/shared';
import styles from './DiceButton.module.css';

/**
 * Pip centres per vary level, in the button's 20×16 inner viewBox:
 * level 0 = one centred pip, dimmed (B3.1 — an empty bordered square
 * beside the row's ✕ reads as an unchecked checkbox, not a die);
 * level 1 = two pips on the diagonal, level 2 = the five-pip quincunx.
 */
const PIPS: Record<VaryLevel, ReadonlyArray<readonly [number, number]>> = {
  0: [[10, 8]],
  1: [
    [6, 5],
    [14, 11],
  ],
  2: [
    [6, 5],
    [14, 5],
    [10, 8],
    [6, 11],
    [14, 11],
  ],
};

/**
 * Accessible name = the CURRENT state (B3 RC1), not the action. The button
 * cycles through THREE states, so it is deliberately NOT `aria-pressed`:
 * a toggle's pressed/not-pressed would announce "a little" and "a lot"
 * identically, and a stateful name already tells a screen-reader user
 * exactly where the control sits.
 */
const LABELS: Record<VaryLevel, string> = {
  0: 'Vary: off',
  1: 'Vary: a little',
  2: 'Vary: a lot',
};

interface DiceButtonProps {
  /** Current vary level — `0` off, `1` a little (±20 %), `2` a lot (±50 %). */
  level: VaryLevel;
  /** Advance one step around the off → a little → a lot → off cycle. */
  onCycle: () => void;
}

/**
 * DiceButton — the 26×22 opt-in "variation" toggle that sits after a
 * counting target (docs/BOARD_SOURCES.md §Member rules; handoff
 * §Interactions "Variation (dice)").
 *
 * Off renders a muted 1.5px outline with one faint centred pip (a die face,
 * not an empty checkbox); on renders a blue fill with `--riso-ink-static`
 * pips — adaptive `--riso-ink` on a coloured fill is the dark-mode trap
 * (see `reference_riso_adaptive_ink_fill_darkmode`).
 *
 * Stateless: the caller owns the level and decides what one tap means, so
 * the same button serves a member, a compound part and a hand-added row.
 *
 * @param level - The current vary level.
 * @param onCycle - Called on tap; the caller advances the cycle.
 * @returns The dice toggle.
 */
export function DiceButton({ level, onCycle }: DiceButtonProps): React.ReactElement {
  const label = LABELS[level];
  return (
    <button
      type="button"
      className={`${styles.dice} ${level > 0 ? styles.on : styles.off}`}
      aria-label={label}
      title={label}
      onClick={onCycle}
    >
      <svg className={styles.pips} viewBox="0 0 20 16" width="20" height="16" aria-hidden="true">
        {PIPS[level].map(([cx, cy]) => (
          <circle key={`${cx}-${cy}`} className={level === 0 ? styles.offPip : undefined} cx={cx} cy={cy} r="1.6" />
        ))}
      </svg>
    </button>
  );
}
