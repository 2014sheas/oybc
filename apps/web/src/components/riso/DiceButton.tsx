import type { VaryLevel } from '@oybc/shared';
import styles from './DiceButton.module.css';

/**
 * Pip centres per vary level, in the button's 24×24 inner viewBox:
 * level 0 = one centred pip, dimmed (B3.1 — an empty bordered square
 * beside the row's ✕ reads as an unchecked checkbox, not a die);
 * level 1 = two pips on the diagonal, level 2 = the five-pip quincunx —
 * a true quincunx now that the box is square.
 *
 * The face grew 22×22 → 28×28 on 2026-09-22 (owner, device-testing #493:
 * the member-row controls were too small to use comfortably), so it no
 * longer sits visibly smaller than the 32px stepper pill beside it and
 * matches the row's 28px ✕. The whole geometry scaled with it: the inner
 * viewBox 18 → 24 (the same 2px inset inside the face), `r` 1.6 → 2, and
 * every coordinate by 24/18, rounded to integers — 9 → 12, 5 → 7,
 * 13 → 17 — identically to the Swift table. The proportions of the B3.1
 * review that set the corners at 5/13 rather than 6/12 are therefore
 * preserved.
 *
 * Clearance to the keyline is now **5.5px**: the outermost pip edge sits
 * at 17 + 2 (r) = 19 in the 24-box, so 21 in face coordinates (the box is
 * centred, inset 2), while the 1.5px border has its inner edge at 26.5 —
 * 26.5 − 21 = 5.5. The worst pip-EDGE gap, corner to centre, is
 * √(5²+5²) = 7.071 − 4 = **3.07px** (was 2.46px at the old scale). The
 * 6px corner radius does not bite — its arc centre is at (6, 6), inside
 * the pip centre on both axes, so the straight edges govern.
 *
 * Coordinate-for-coordinate identical to the Swift twin's `pips` table
 * (`RisoDiceButton.swift`); pinned on both platforms so a one-sided tweak
 * can't ship.
 */
const PIPS: Record<VaryLevel, ReadonlyArray<readonly [number, number]>> = {
  0: [[12, 12]],
  1: [
    [7, 7],
    [17, 17],
  ],
  2: [
    [7, 7],
    [17, 7],
    [12, 12],
    [7, 17],
    [17, 17],
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
 * DiceButton — the 28×28 opt-in "variation" toggle that sits after a
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
      <svg className={styles.pips} viewBox="0 0 24 24" width="24" height="24" aria-hidden="true">
        {PIPS[level].map(([cx, cy]) => (
          <circle key={`${cx}-${cy}`} className={level === 0 ? styles.offPip : undefined} cx={cx} cy={cy} r="2" />
        ))}
      </svg>
    </button>
  );
}
