import { useEffect } from 'react';
import styles from './Play.module.css';

/** Auto-dismiss duration in ms. */
const TOAST_MS = 2600;

export interface RisoCreditedToastProps {
  /** The counter's display name, e.g. "Sit-ups". */
  name: string;
  /**
   * Positive = increment ("logged"), negative = decrement ("removed").
   * Zero is never shown — callers must suppress the toast for no-ops.
   */
  delta: number;
  /**
   * Board names the increment/decrement also applied to (excluding the
   * current board). Must have ≥ 1 entry; callers suppress the toast when
   * the list is empty.
   */
  boardNames: string[];
  /** Called once after the auto-dismiss timer expires. */
  onDone: () => void;
}

/**
 * Credited toast — confirms that a shared-counter log/remove also
 * propagated to other boards.
 *
 * Copy contract (verbatim):
 *   increment: "{name} logged — also counted on {A, B}."
 *   decrement: "{name} removed — also taken off {A, B}."
 *
 * Auto-dismisses after 2.6 s. Mount a new instance (different `key`) for
 * each new toast so the timer resets cleanly.
 *
 * Mirrors the prototype's `.cn-credit-toast` card from
 * `design_handoff_shared_counters/proto/counters.css`.
 */
export function RisoCreditedToast({ name, delta, boardNames, onDone }: RisoCreditedToastProps): React.ReactElement {
  useEffect(() => {
    const id = setTimeout(onDone, TOAST_MS);
    return () => clearTimeout(id);
  }, [onDone]);

  const isIncrement = delta >= 0;
  const boardsStr = boardNames.join(', ');
  const verb = isIncrement ? 'logged' : 'removed';
  const prep = isIncrement ? 'counted on' : 'taken off';

  return (
    <div
      className={styles.creditedToast}
      role="status"
      aria-live="polite"
      aria-atomic="true"
    >
      <span className={styles.creditedToastDot} aria-hidden="true">↔</span>
      <span className={styles.creditedToastTxt}>
        <strong>{name}</strong>
        {' '}{verb} — also {prep} {boardsStr}.
      </span>
    </div>
  );
}
