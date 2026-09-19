import { useState } from 'react';
import { compactStepperBase } from './counterStepperMath';
import styles from './CounterStepper.module.css';

interface CounterStepperProps {
  /** Current value */
  value: number;
  /** Minimum allowed value */
  min: number;
  /** Maximum allowed value */
  max: number;
  /** Callback when the value changes */
  onChange: (value: number) => void;
  /**
   * Optional label shown after the stepper (e.g. "of 5 subtasks"). On the
   * `compact` variant it becomes the numeric field's accessible name
   * instead of the default "Target" (there's no room to render it visibly
   * — see `suffix` below for the visible goal text).
   */
  label?: string;
  /**
   * `default` (the compound builder's −/+ pair) or `compact` — the 22px
   * pill used by the wizard's member rows (docs/BOARD_SOURCES.md §Member
   * rules): 1.5px ink border, radius 999, a typeable numeric middle.
   */
  size?: 'default' | 'compact';
  /**
   * Static text rendered inside the compact pill after the value — the
   * member row's goal ("/ 30 Miles"), folded in so the row does not need
   * a separate caption beside the stepper (B3.1). Not editable; only the
   * numeric field is. Ignored by the `default` size.
   */
  suffix?: string;
}

/**
 * CounterStepper — Increment/decrement control with min/max bounds.
 *
 * Provides a −/+ button pair flanking a value display. Used in the
 * composite task form for M_OF_N threshold selection and potentially
 * in the detail modal for counting task adjustments.
 *
 * The `compact` variant swaps the static value for a numeric text field
 * (select-all on focus, committed on blur/Enter, clamped to `[min, max]`)
 * and names its controls for screen readers ("Decrease target" /
 * "Increase target" / "Target") — the wizard's member-row target editor.
 *
 * @param value - Current counter value
 * @param min - Minimum bound (decrement disabled at this value)
 * @param max - Maximum bound (increment disabled at this value)
 * @param onChange - Called with the new value on button click
 * @param label - Optional trailing label text
 * @param size - Visual variant (see above)
 * @returns The stepper control.
 */
export function CounterStepper({
  value,
  min,
  max,
  onChange,
  label,
  size = 'default',
  suffix,
}: CounterStepperProps): React.ReactElement {
  /** Uncommitted typing in the compact field; `null` while not editing. */
  const [draft, setDraft] = useState<string | null>(null);

  if (size === 'compact') {
    // The −/+ buttons gate on the UNCOMMITTED draft when there is one, so a
    // typed-but-unblurred `1` in a `min: 1` field disables `−` immediately
    // (iOS `RisoCompactStepperMath.base`).
    const gateValue = compactStepperBase(value, draft, min, max);
    const commit = (): void => {
      if (draft === null) return;
      const parsed = Number.parseInt(draft.trim(), 10);
      setDraft(null);
      if (!Number.isFinite(parsed)) return;
      const clamped = Math.min(max, Math.max(min, parsed));
      if (clamped !== value) onChange(clamped);
    };
    return (
      <span className={styles.compactPill}>
        <button
          type="button"
          className={styles.compactButton}
          onClick={() => onChange(Math.max(min, value - 1))}
          disabled={gateValue <= min}
          aria-label="Decrease target"
        >
          −
        </button>
        <input
          type="text"
          inputMode="numeric"
          className={styles.compactInput}
          aria-label={label ?? 'Target'}
          // Sized to the goal's digit count so a 4-digit goal isn't clipped.
          style={{ width: `${Math.max(2, String(max).length) + 1}ch` }}
          value={draft ?? String(value)}
          onFocus={(e) => {
            setDraft(String(value));
            e.currentTarget.select();
          }}
          onChange={(e) => setDraft(e.currentTarget.value)}
          onBlur={commit}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              e.currentTarget.blur();
            }
          }}
        />
        {suffix !== undefined && (
          // Redundant with the member row's own accessible label (the goal
          // is carried there) — hidden from AT so it isn't announced twice
          // as an isolated, unlabelled fragment. Web twin of iOS's
          // `.accessibilityHidden(true)` on the same text (B3.1).
          <span className={styles.compactSuffix} data-testid="stepper-suffix" aria-hidden="true">
            {suffix}
          </span>
        )}
        <button
          type="button"
          className={styles.compactButton}
          onClick={() => onChange(Math.min(max, value + 1))}
          disabled={gateValue >= max}
          aria-label="Increase target"
        >
          ＋
        </button>
      </span>
    );
  }

  return (
    <div className={styles.stepperRow}>
      <button
        type="button"
        className={styles.stepperButton}
        onClick={() => onChange(Math.max(min, value - 1))}
        disabled={value <= min}
      >
        −
      </button>
      <span className={styles.stepperValue}>{value}</span>
      <button
        type="button"
        className={styles.stepperButton}
        onClick={() => onChange(Math.min(max, value + 1))}
        disabled={value >= max}
      >
        +
      </button>
      {label && <span className={styles.stepperLabel}>{label}</span>}
    </div>
  );
}
