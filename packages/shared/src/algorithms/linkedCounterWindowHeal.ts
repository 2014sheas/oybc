/**
 * linkedCounterWindowHeal.ts — what survives of the windowed-linked-counter
 * heal (owner rule 2026-10-01; the heal itself was retired in
 * TASK_WINDOW_REWORK slice 3a, 2026-10-18 — writers no longer mint per-board
 * rows, they write placement parameters):
 *
 *   - {@link sameWindowStart} — one instant-compare for window starts.
 *   - {@link isWindowStampedForBoard} — is a row THIS board's own per-window
 *     artifact (window-stamped AND stamped for this board's window)? Read by
 *     the mint-for-board check until the slice-4 sweep repoints those rows.
 *
 * Swift twin: `Helpers/LinkedCounterWindowHeal.swift`.
 */

import type { Board } from '../types/board';
import type { Task } from '../types/task';
import { isWindowStampedDerived } from './memberRules';

/**
 * Do two stored `startDate`s name the same window opening?
 *
 * `Board.startDate` has TWO live encodings — the local ISO the wizard writes
 * (`2026-09-18T00:00:00`, no offset) and the full UTC form a sync round-trip
 * can hand back — and a derived row copies whichever one its board carried at
 * mint time. Those two never compare equal as strings, so a plain `!==` would
 * answer "not mine" for a re-encoded pull. Comparing INSTANTS is what makes
 * the two encodings agree; a stamp that doesn't parse on either side falls
 * back to string equality rather than claiming a match. Two absent values are
 * equal; an absent and a present one are not.
 *
 * (Moved here from web's `derivedCounters.ts` so both platforms and
 * {@link isWindowStampedForBoard} share one definition.)
 *
 * @param a - One stored start date (a derived row's).
 * @param b - The other (its candidate board's).
 * @returns True when both name the same instant (or the same literal string).
 */
export function sameWindowStart(a: string | null | undefined, b: string | null | undefined): boolean {
  if (a == null || b == null) return a === b;
  const ta = Date.parse(a);
  const tb = Date.parse(b);
  if (Number.isNaN(ta) || Number.isNaN(tb)) return a === b;
  return ta === tb;
}

/**
 * Is `task` a window-stamped derived counter stamped for THIS board's window
 * — i.e. the row a placement on `board` may point at as-is?
 *
 * The placement choke points' gate: placing a task with a `sharedCounterId`
 * that is NOT window-stamped for the target board (not window-stamped at all,
 * or stamped for a different window) must resolve to that board's own
 * per-window row (`derivedTaskId(board.id, root)`) instead. Only the window
 * START is compared ({@link sameWindowStart}); a row minted for this window
 * carries this board's `endDate` too, and a Board-Edit date change refreshes
 * it through its own path.
 *
 * @param task - The row about to be placed.
 * @param board - The board it is being placed on.
 * @returns True when the row is this board's own window-stamped artifact.
 */
export function isWindowStampedForBoard(
  task: Pick<Task, 'sharedCounterId' | 'startDate' | 'createdInWizard'>,
  board: Pick<Board, 'startDate'>
): boolean {
  return isWindowStampedDerived(task) && sameWindowStart(task.startDate, board.startDate);
}
