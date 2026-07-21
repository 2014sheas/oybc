import { useEffect } from 'react';
import styles from './CounterLogToast.module.css';

/** Auto-dismiss duration in ms (design handoff §Interactions — "auto-dismiss ~4s"). */
const TOAST_MS = 4000;

export interface CounterLogToastProps {
  /** Amount just logged (always positive — see `verb`). */
  amount: number;
  /** The counter's unit noun, e.g. "push-ups". */
  unit: string;
  /**
   * `'logged'` for an increment (Hub "+ Log" pill / Detail "+ Add N"),
   * `'removed'` for a decrement (Detail "−" button). Copy contract:
   *   logged:  "Logged +{N} {noun} · Undo"
   *   removed: "Removed {N} {noun} · Undo"
   */
  verb: 'logged' | 'removed';
  /** Reverses the log entry (`undoLastCounterLog`). Disabled while pending. */
  onUndo: () => void;
  /** Called once after the auto-dismiss timer expires OR after Undo resolves. */
  onDone: () => void;
}

/**
 * CounterLogToast — reusable "Logged +N · Undo" toast (R2 Counters UX
 * refresh — design handoff Locked decision 3). Shown by the Counters Hub
 * ("+ Log" pill) and Counter Detail (Log card) after every log/remove.
 *
 * Deliberately a NEW component rather than an extension of the board-play
 * `RisoCreditedToast` (`components/play/RisoCreditedToast.tsx`): that toast
 * has a fixed, different copy contract ("{name} logged — also counted on
 * {boards}.") wired to board-play's cross-board crediting story and carries
 * no Undo affordance. This toast's contract (amount + Undo, no board list)
 * is a different shape, not a variant of the same copy — forcing them into
 * one component would mean branching copy/props against unrelated designs.
 * R3 board-play is expected to reuse THIS component (not `RisoCreditedToast`)
 * once its touchpoints add amount-aware logging with Undo.
 *
 * Mount a new instance (different `key`) per toast so the auto-dismiss
 * timer resets cleanly — same convention as `RisoCreditedToast`.
 */
export function CounterLogToast({
  amount,
  unit,
  verb,
  onUndo,
  onDone,
}: CounterLogToastProps): React.ReactElement {
  useEffect(() => {
    // Capture onDone once at mount — see RisoCreditedToast's identical note:
    // a parent re-render must not restart the timer.
    const id = setTimeout(onDone, TOAST_MS);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const verbLabel = verb === 'logged' ? `Logged +${amount}` : `Removed ${amount}`;

  return (
    <div className={styles.toast} role="status" aria-live="polite" aria-atomic="true">
      <span className={styles.text}>
        {verbLabel} {unit}
      </span>
      <button type="button" className={styles.undoBtn} onClick={onUndo}>
        Undo
      </button>
    </div>
  );
}
