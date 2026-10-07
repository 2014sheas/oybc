import styles from './CounterLinkHint.module.css';

export interface CounterLinkHintProps {
  /** The matched counter's pair-derived display name. */
  counterName: string;
  /** Whether this create currently links to the counter. */
  linked: boolean;
  /** Toggles the link on/off for this create. */
  onToggle: () => void;
}

/**
 * CounterLinkHint — the matched counter + the link toggle (R1 counters
 * refresh). The kind tag beside the Goal carries the family's total (#548
 * rows 77/78). One component for every counting-task creation surface.
 *
 * Blue fill — dark-mode contract: content uses `--riso-on-color` /
 * `--riso-ink-static`, never adaptive `--riso-ink`, on a fixed colored fill.
 */
export function CounterLinkHint({ counterName, linked, onToggle }: CounterLinkHintProps): React.ReactElement {
  return (
    <div className={styles.hint} role="region" aria-label="Counter link">
      <p className={styles.hintTitle}>{counterName}</p>
      <button
        type="button"
        className={styles.hintPill}
        onClick={onToggle}
        aria-label={linked ? `Don't link to ${counterName}` : `Link to ${counterName}`}
      >
        {linked ? "Don't link" : 'Link'}
      </button>
    </div>
  );
}
