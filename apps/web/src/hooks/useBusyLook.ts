import { useEffect, useState } from 'react';

/**
 * How long a write may run before the controls take their busy look (opacity
 * 0.45, hard shadow collapsed) — docs/TASK_DETAIL_REDESIGN.md decision 6,
 * amended 2026-10-18. Mirrored on iOS as 250 ms. A write that settles faster
 * never dims anything: the controls were already non-interactive.
 */
export const BUSY_LOOK_DELAY_MS = 250;

/**
 * Starts the busy-look countdown.
 *
 * @param onLate - Called once if the countdown is not cancelled first.
 * @param delayMs - The countdown.
 * @returns Cancels the countdown.
 */
export function scheduleBusyLook(onLate: () => void, delayMs: number = BUSY_LOOK_DELAY_MS): () => void {
  const timer = setTimeout(onLate, delayMs);
  return () => clearTimeout(timer);
}

/**
 * Whether the controls should LOOK busy: true only once `busy` has held for
 * {@link BUSY_LOOK_DELAY_MS}. Interactivity is separate — callers keep their
 * re-entrancy guard on `busy` itself, so a control is inert at once and merely
 * dims late.
 *
 * @param busy - A write is in flight.
 * @param delayMs - The countdown (tests only).
 * @returns The delayed flag.
 */
export function useBusyLook(busy: boolean, delayMs: number = BUSY_LOOK_DELAY_MS): boolean {
  const [late, setLate] = useState(false);
  useEffect(() => {
    if (!busy) return undefined;
    const cancel = scheduleBusyLook(() => setLate(true), delayMs);
    return () => {
      cancel();
      setLate(false);
    };
  }, [busy, delayMs]);
  return busy && late;
}
