import { useEffect } from 'react';
import { formatCounterLogToastText } from './counterLogToastText';
import styles from './CounterLogToast.module.css';

/** Auto-dismiss duration in ms (design handoff §Interactions — "auto-dismiss ~4s"). */
const TOAST_MS = 4000;

export interface CounterLogToastProps {
  /** Amount just logged (always positive — see `verb`). */
  amount: number;
  /** The counter's unit noun, e.g. "push-ups". Used by the standalone
   *  (Hub/Detail) copy; ignored when `boardNames` drives the credited copy. */
  unit: string;
  /**
   * `'logged'` for an increment (Hub "+ Log" pill / Detail "+ Add N" / board
   * tap or quick-add), `'removed'` for a decrement (Detail "−" button /
   * board quick-remove).
   */
  verb: 'logged' | 'removed';
  /**
   * Board-play only (R3): the counter's pair-derived display name
   * (`formatCounterName` result, stored-title fallback — never raw
   * `task.title`). Required together with `boardNames` for the credited
   * copy variant; unused by the standalone Hub/Detail copy.
   */
  counterName?: string;
  /**
   * Board-play only (R3): other boards this log also applied to (excluding
   * the board being played). When present and non-empty, renders the R3
   * copy-contract crediting sentence instead of the standalone "Logged +N
   * {unit}" copy. Callers must omit/empty this when there are no other
   * boards — the credited variant never shows for a non-shared log (existing
   * trigger condition, preserved from the retired `RisoCreditedToast`).
   */
  boardNames?: string[];
  /** Reverses the log entry (`undoLastCounterLog`). Disabled while pending. */
  onUndo: () => void;
  /** Called once after the auto-dismiss timer expires OR after Undo resolves. */
  onDone: () => void;
}

/**
 * CounterLogToast — reusable "Logged +N · Undo" toast (R2 Counters UX
 * refresh — design handoff Locked decision 3). Shown by the Counters Hub
 * ("+ Log" pill), Counter Detail (Log card), and — as of R3 — board-play's
 * shared-counter touchpoints (grid tap / detail modal / context menu).
 *
 * Two copy variants, selected by whether `boardNames` is a non-empty array:
 *   - Standalone (Hub/Detail, no `boardNames`): "Logged +{N} {unit}" /
 *     "Removed {N} {unit}".
 *   - Credited (board-play, R3 copy contract): "+{N} {counterName} — also
 *     counted on {board list}." / "−{N} {counterName} — also removed from
 *     {board list}." — board list is a plain comma-join, unchanged from the
 *     retired `RisoCreditedToast`.
 *
 * R3 retired the board-play-only `components/play/RisoCreditedToast.tsx`
 * (no Undo, fixed copy, 2.6s dismiss) in favor of extending this component —
 * exactly the merge its R2 docstring flagged as the expected R3 outcome, so
 * board-play now gets Undo + the ~4s dismiss window for free.
 *
 * Mount a new instance (different `key`) per toast so the auto-dismiss
 * timer resets cleanly.
 */
export function CounterLogToast({
  amount,
  unit,
  verb,
  counterName,
  boardNames,
  onUndo,
  onDone,
}: CounterLogToastProps): React.ReactElement {
  useEffect(() => {
    // Capture onDone once at mount — a parent re-render (e.g. a live-query
    // update after the write this toast reports) must not restart the timer.
    const id = setTimeout(onDone, TOAST_MS);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const text = formatCounterLogToastText({ amount, unit, verb, counterName, boardNames });

  return (
    <div className={styles.toast} role="status" aria-live="polite" aria-atomic="true">
      <span className={styles.text}>{text}</span>
      <button type="button" className={styles.undoBtn} onClick={onUndo}>
        Undo
      </button>
    </div>
  );
}
