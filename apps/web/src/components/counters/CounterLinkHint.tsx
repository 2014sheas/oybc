import styles from './CounterLinkHint.module.css';

export interface CounterLinkHintProps {
  /** The matched counter's pair-derived display name (`formatCounterName`),
   *  e.g. "Push-ups" or "Run miles". */
  counterName: string;
  /** The matched counter's all-time lifetime total. */
  lifetime: number;
  /** The new task's own goal (`maxCount`) — shown in the "0–{goal} window"
   *  sub-copy. Caller only renders this component once a valid positive
   *  goal exists. */
  goal: number;
  /** Whether this create currently links to the counter. */
  linked: boolean;
  /** Toggles the link on/off for this create. */
  onToggle: () => void;
}

/**
 * CounterLinkHint — the always-visible auto-link hint card (R1 counters
 * refresh, "Refining counters" design handoff §Creation Surfaces).
 *
 * Replaces the old suggest-confirm suggestion card. When a counting task's
 * typed (verb, noun) pair exactly matches an existing counter, linking is ON
 * by default — this card explains what will happen and offers a "Don't
 * link" opt-out (toggling back to "Link" re-enables it). It's a single
 * reusable component so the identical hint renders across every counting-
 * task creation surface (CountingTemplatePicker → CreateNewTaskForm /
 * NewTaskSheet / the board wizard, and the compound builder's SubtaskCard)
 * rather than being triplicated per host.
 *
 * Blue fill — dark-mode contract: content uses `--riso-on-color` /
 * `--riso-ink-static`, never adaptive `--riso-ink`, on a fixed colored fill.
 */
export function CounterLinkHint({
  counterName,
  lifetime,
  goal,
  linked,
  onToggle,
}: CounterLinkHintProps): React.ReactElement {
  return (
    <div className={styles.hint} role="region" aria-label="Counter link">
      <div className={styles.hintText}>
        <p className={styles.hintTitle}>
          {linked ? `Counts toward your ${counterName} counter` : `Won't count toward ${counterName}`}
        </p>
        <p className={styles.hintSub}>
          {linked
            ? `${lifetime.toLocaleString()} all-time · this task keeps its own 0–${goal} window`
            : 'Creates a separate, unlinked counter.'}
        </p>
      </div>
      <button type="button" className={styles.hintPill} onClick={onToggle}>
        {linked ? "Don't link" : 'Link'}
      </button>
    </div>
  );
}
