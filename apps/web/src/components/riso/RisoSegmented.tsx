import type { ReactNode } from 'react';
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
  'aria-label': ariaLabel,
}: RisoSegmentedProps<T>): React.ReactElement {
  return (
    <div className={variant === 'pill' ? styles.pill : styles.card} role="group" aria-label={ariaLabel}>
      {options.map((opt) => {
        const selected = opt.value === value;
        return (
          <button
            key={String(opt.value)}
            type="button"
            className={[styles.seg, selected ? styles.on : ''].filter(Boolean).join(' ')}
            aria-pressed={selected}
            onClick={() => onChange(opt.value)}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}
