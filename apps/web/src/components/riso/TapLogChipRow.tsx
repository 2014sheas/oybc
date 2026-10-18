import type { TapLogChip } from '@oybc/shared';
import { chipKey } from './chipKey';
import styles from './TapLogChipRow.module.css';

export interface TapLogChipRowProps {
  /** The `tapLogChips` output: presets, an optional rest chip, "Other…". */
  chips: ReadonlyArray<TapLogChip>;
  /** `regular` 44px (sheet / hero), `compact` 34px (compound child rows). */
  size?: 'regular' | 'compact';
  /** The busy look — opacity 0.45, hard shadow collapsed, layout unchanged. Really disabled. */
  disabled?: boolean;
  /**
   * A write is in flight but the busy look has not shown yet (it waits ~250 ms):
   * the chips look live and swallow taps, so the re-entrancy guard holds at once.
   */
  inert?: boolean;
  /** The unit noun for the chips' accessible names ("Log +10 pages"); omit for duration / unit-less. */
  unit?: string;
  /** Accessible name of the group. */
  label?: string;
  /** Fired once per tap; the caller writes immediately (no pick-then-press). */
  onChip: (chip: TapLogChip) => void;
}

/** A rest label this long takes the wider flex at the smaller type size. */
const LONG_REST_LABEL = 4;

/** "Log +10 pages" / "Log the rest, +8 pages" / "Log another amount". */
function chipName(chip: TapLogChip, unit: string): string {
  if (chip.role === 'other') return 'Log another amount';
  const suffix = unit ? ` ${unit}` : '';
  if (chip.role === 'rest') return `Log the rest, ${chip.label.replace(/\s*✓$/, '')}${suffix}`;
  return `Log ${chip.label}${suffix}`;
}

/**
 * TapLogChipRow — the one-gesture log control (docs/TASK_DETAIL_REDESIGN.md
 * E3): gold preset / rest chips with an `inkStatic` keyline and a hard shadow,
 * and a paper "Other…" chip. iOS twin: `TapLogChipRow`.
 *
 * @returns The chip row.
 */
export function TapLogChipRow({ chips, size = 'regular', disabled = false, inert = false, unit = '', label = 'Log amount', onChip }: TapLogChipRowProps): React.ReactElement {
  return (
    <div className={`${styles.row} ${size === 'compact' ? styles.compact : ''}`} role="group" aria-label={label}>
      {chips.map((chip) => {
        const long = chip.role === 'rest' && chip.label.length >= LONG_REST_LABEL;
        const cls = [styles.chip, chip.role === 'other' ? styles.other : styles.gold, long ? styles.long : ''].filter(Boolean).join(' ');
        return (
          <button
            key={chipKey(chip)}
            type="button"
            className={cls}
            disabled={disabled}
            aria-disabled={inert || undefined}
            aria-label={chipName(chip, unit)}
            onClick={() => { if (!inert) onChip(chip); }}
          >
            {chip.label}
          </button>
        );
      })}
    </div>
  );
}
