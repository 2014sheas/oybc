import type { ReactNode } from 'react';
import { RisoIcon } from './RisoIcon';
import styles from './RisoSegmented.module.css';

export interface RisoSegmentedOption<T> {
  value: T;
  label: ReactNode;
}

export interface RisoSegmentedProps<T> {
  /** Selectable options, rendered left-to-right. */
  options: ReadonlyArray<RisoSegmentedOption<T>>;
  /** Currently-selected value. */
  value: T;
  /** Called with the chosen value when a segment is pressed. */
  onChange: (value: T) => void;
  /**
   * `card` (default) = bordered buttons, blue active — the prominent
   * wizard/preferences picker. `pill` = rounded compact toggle, ink active.
   */
  variant?: 'card' | 'pill';
  /**
   * `default` (the shipped metrics) or `compact` — for `pill`, a 22px-tall
   * pill with a 1.5px ink border and 10.5/700 segments (the wizard member
   * row's One square / Split up); for `card`, smaller bordered buttons
   * (~13px/700, 1.5px border, no fixed min-width) sized for a right-aligned
   * inline row control (Board settings' Size / Center square / Week starts
   * rows) rather than the default 90px-min-width prominent picker.
   */
  size?: 'default' | 'compact';
  /**
   * `card` variant only: stretches the control to fill its container width,
   * splitting evenly across the options with NO wrap — for a fixed-count
   * full-width row (Board settings' 5-option Timeframe picker, which must
   * not wrap even at a 393px viewport). Ignored for `pill`.
   */
  fullWidth?: boolean;
  /**
   * `card` + `fullWidth` only: labels never ellipsize — the type scales with
   * the row's width (container units) between 9px and the size's own font
   * size. For short fixed label sets in narrow rows (the counter-kind
   * picker's "Continuous" in a nested compound sub-task at 390px).
   */
  fitLabels?: boolean;
  /**
   * `card` only: values whose segment ignores taps — 45% opacity, not
   * hit-testable, `aria-disabled`. The counter-kind picker's locked states
   * (docs/COUNTER_KINDS.md §5). Omitted ⇒ unchanged markup.
   */
  lockedValues?: ReadonlyArray<T>;
  /** `card` only: values whose segment carries the lock glyph. */
  lockGlyphValues?: ReadonlyArray<T>;
  /**
   * Accessible group label — REQUIRED. A `role="group"` with no accessible
   * name fails WCAG 1.3.1, so the kit forces callers to name the control.
   */
  'aria-label': string;
}

/**
 * Riso segmented control — the generic single-select picker used for
 * timeframe / board size / center square (card form) and theme / compact
 * toggles (pill form). Mirrors the iOS generic `RisoSegmented<T>`.
 *
 * Generic over the value type so callers keep their own enums/unions.
 */
export function RisoSegmented<T extends string | number>({
  options,
  value,
  onChange,
  variant = 'card',
  size = 'default',
  fullWidth = false,
  fitLabels = false,
  lockedValues,
  lockGlyphValues,
  'aria-label': ariaLabel,
}: RisoSegmentedProps<T>): React.ReactElement {
  return (
    <div
      className={[
        variant === 'pill' ? styles.pill : styles.card,
        size === 'compact' ? styles.compact : '',
        variant === 'card' && fullWidth ? styles.fullWidth : '',
        variant === 'card' && fullWidth && fitLabels ? styles.fitLabels : '',
      ]
        .filter(Boolean)
        .join(' ')}
      style={
        variant === 'card' && fullWidth && fitLabels
          ? ({ '--seg-count': options.length } as React.CSSProperties)
          : undefined
      }
      role="group"
      aria-label={ariaLabel}
    >
      {options.map((opt) => {
        const selected = opt.value === value;
        // card-only by contract: the pill variants ignore locks.
        const locked = variant === 'card' && (lockedValues?.includes(opt.value) ?? false);
        const glyph = variant === 'card' && (lockGlyphValues?.includes(opt.value) ?? false);
        return (
          <button
            key={String(opt.value)}
            type="button"
            className={[styles.seg, selected ? styles.on : '', locked ? styles.locked : ''].filter(Boolean).join(' ')}
            aria-pressed={selected}
            aria-disabled={locked ? true : undefined}
            onClick={locked ? undefined : () => onChange(opt.value)}
          >
            {opt.label}
            {glyph && (
              <span className={styles.lockGlyph} aria-hidden="true">
                <RisoIcon name="lock" size={11} />
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
}
