import type { VaryLevel } from '@oybc/shared';
import styles from './DiceButton.module.css';

/**
 * Pip centres per vary level, in the button's 18×18 inner viewBox:
 * level 0 = one centred pip, dimmed (B3.1 — an empty bordered square
 * beside the row's ✕ reads as an unchecked checkbox, not a die);
 * level 1 = two pips on the diagonal, level 2 = the five-pip quincunx —
 * a true quincunx now that the box is square.
 *
 * The corners sit at 5/13 rather than 6/12 (B3.1 review): at 6/12 the
 * worst gap — corner to centre — was √(3²+3²) = 4.243 between centres
 * minus the 3.2 pip diameter = **1.04px**, and the whole pattern spanned
 * 6×6 inside a 22×22 face, reading as a tight cluster in a wide margin.
 * Pulling the corners out one step on each axis gives **2.46px** on the
 * diagonal (√(4²+4²) = 5.657 − 3.2) and an 8×8 span, while keeping
 * **3.9px** of clearance to the keyline: a corner centre lands at 7 in
 * face coordinates (the 18-box is inset 2 by the 1.5 border + 0.5 of
 * centring), so 7 − 1.6 (r) − 1.5 (border) = 3.9. The 6px corner radius
 * does not bite — its arc centre is at (6, 6), inside the pip centre on
 * both axes, so the straight edges govern. The centre pip and `r` are
 * unchanged.
 *
 * Coordinate-for-coordinate identical to the Swift twin's `pips` table
 * (`RisoDiceButton.swift`); pinned on both platforms so a one-sided tweak
 * can't ship.
 */
const PIPS: Record<VaryLevel, ReadonlyArray<readonly [number, number]>> = {
  0: [[9, 9]],
  1: [
    [5, 5],
    [13, 13],
  ],
  2: [
    [5, 5],
    [13, 5],
    [9, 9],
    [5, 13],
    [13, 13],
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
 * DiceButton — the 22×22 opt-in "variation" toggle that sits after a
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
      <svg className={styles.pips} viewBox="0 0 18 18" width="18" height="18" aria-hidden="true">
        {PIPS[level].map(([cx, cy]) => (
          <circle key={`${cx}-${cy}`} className={level === 0 ? styles.offPip : undefined} cx={cx} cy={cy} r="1.6" />
        ))}
      </svg>
    </button>
  );
}
