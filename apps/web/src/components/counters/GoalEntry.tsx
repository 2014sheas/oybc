import { useState } from 'react';
import { durationFromFields, durationToFields, parseCountInput, type CountKind } from '@oybc/shared';
import { goalEntryInputMode } from './goalEntryModel';
import styles from './GoalEntry.module.css';

export interface GoalEntryProps {
  kind: CountKind;
  /** Field text in `parseCountInput` grammar (Duration: `'Xh Ym'` or `''`). */
  value: string;
  onChange: (next: string) => void;
  id?: string;
  'aria-label'?: string;
  placeholder?: string;
  /** Unit text inside the field's right edge (Discrete / Continuous only). */
  suffix?: string;
  dense?: boolean;
  invalid?: boolean;
  autoFocus?: boolean;
  /** Enter key — the custom-amount rows commit on it. */
  onEnter?: () => void;
  /** Escape key — the custom-amount rows close on it. */
  onEscape?: () => void;
}

/**
 * The one amount-entry field (docs/COUNTER_KINDS.md §5): numeric for
 * Discrete, decimal for Continuous, two `[h] h [m] m` fields for Duration.
 * Text-typed (never `type="number"`) so `,` decimals and partial entries
 * survive typing; callers validate with `parseCountInput`. iOS twin:
 * `GoalEntryView`.
 *
 * @returns The field.
 */
export function GoalEntry(props: GoalEntryProps): React.ReactElement {
  const { kind, value, onChange, id, placeholder, suffix, dense, invalid, autoFocus, onEnter, onEscape } = props;
  const label = props['aria-label'];
  const fieldClass = [styles.field, dense ? styles.dense : '', invalid ? styles.invalid : ''].filter(Boolean).join(' ');
  const onKeyDown = (e: React.KeyboardEvent<HTMLInputElement>): void => {
    if (e.key === 'Enter' && onEnter) { e.preventDefault(); onEnter(); }
    if (e.key === 'Escape' && onEscape) { e.preventDefault(); onEscape(); }
  };
  if (kind === 'duration') {
    return <DurationFields {...{ value, onChange, id, label, fieldClass, autoFocus, onKeyDown }} />;
  }
  return (
    <span className={fieldClass}>
      <input
        id={id}
        type="text"
        inputMode={goalEntryInputMode(kind)}
        className={styles.input}
        value={value}
        placeholder={placeholder ?? '100'}
        aria-label={label}
        aria-invalid={invalid || undefined}
        autoFocus={autoFocus}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={onKeyDown}
      />
      {suffix && <span className={styles.suffix}>{suffix}</span>}
    </span>
  );
}

function DurationFields(p: {
  value: string; onChange: (v: string) => void; id?: string; label?: string;
  fieldClass: string; autoFocus?: boolean; onKeyDown: (e: React.KeyboardEvent<HTMLInputElement>) => void;
}): React.ReactElement {
  // Local field text so "1" then "15" in minutes doesn't re-normalise mid-typing;
  // re-seeded only when the parent's value stops matching what we emitted.
  const [fields, setFields] = useState(() => durationToFields(parseCountInput(p.value, 'duration', { allowZero: true })));
  const emitted = durationFromFields(fields.hours, fields.minutes);
  const external = parseCountInput(p.value, 'duration', { allowZero: true });
  if (external !== parseCountInput(emitted, 'duration', { allowZero: true }) && !(p.value === '' && emitted === '')) {
    setFields(durationToFields(external));
  }
  const set = (next: { hours: string; minutes: string }): void => {
    setFields(next);
    p.onChange(durationFromFields(next.hours, next.minutes));
  };
  return (
    <span className={styles.duration}>
      <span className={p.fieldClass}>
        <input id={p.id} type="text" inputMode="numeric" className={styles.input} value={fields.hours} placeholder="0"
          aria-label={p.label ? `${p.label} hours` : 'Hours'} autoFocus={p.autoFocus}
          onChange={(e) => set({ ...fields, hours: e.target.value })} onKeyDown={p.onKeyDown} />
      </span>
      <span className={styles.unit} aria-hidden="true">h</span>
      <span className={p.fieldClass}>
        <input type="text" inputMode="numeric" className={styles.input} value={fields.minutes} placeholder="00"
          aria-label={p.label ? `${p.label} minutes` : 'Minutes'}
          onChange={(e) => set({ ...fields, minutes: e.target.value })} onKeyDown={p.onKeyDown} />
      </span>
      <span className={styles.unit} aria-hidden="true">m</span>
    </span>
  );
}
