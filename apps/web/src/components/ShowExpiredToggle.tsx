import styles from './ShowExpiredToggle.module.css';

interface ShowExpiredToggleProps {
  /** Whether expired rows are currently shown. */
  checked: boolean;
  /** Called with the new value on toggle. */
  onChange: (value: boolean) => void;
}

/**
 * ShowExpiredToggle — the one "Show expired tasks" checkbox in the app.
 *
 * Phase 6.Y (Timeboxed Tasks) gave the Tasks tab a default-hide rule for
 * tasks past their `endDate`; §Member rules (B3, RC9) gave the Counters hub
 * the same need, because a per-window derived counter expires with its
 * board's window. Extracted from `pages/tasks/TasksFilterControls.tsx` so
 * both surfaces render the identical control, class and copy rather than a
 * second near-miss of the same sentence.
 *
 * @param checked - Whether expired rows are currently shown.
 * @param onChange - Receives the new value.
 * @returns The labelled checkbox.
 */
export function ShowExpiredToggle({
  checked,
  onChange,
}: ShowExpiredToggleProps): React.ReactElement {
  return (
    <label className={styles.label}>
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span className={styles.labelText}>Show expired tasks</span>
    </label>
  );
}
