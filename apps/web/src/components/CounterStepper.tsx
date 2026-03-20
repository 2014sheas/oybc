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
  /** Optional label shown after the stepper (e.g. "of 5 subtasks") */
  label?: string;
}

/**
 * CounterStepper — Increment/decrement control with min/max bounds.
 *
 * Provides a −/+ button pair flanking a value display. Used in the
 * composite task form for M_OF_N threshold selection and potentially
 * in the detail modal for counting task adjustments.
 *
 * @param value - Current counter value
 * @param min - Minimum bound (decrement disabled at this value)
 * @param max - Maximum bound (increment disabled at this value)
 * @param onChange - Called with the new value on button click
 * @param label - Optional trailing label text
 */
export function CounterStepper({ value, min, max, onChange, label }: CounterStepperProps): React.ReactElement {
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
