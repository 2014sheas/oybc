import type { TaskEvent } from '../types/taskEvent';
import { SEED_EVENT_OCCURRED_AT } from './taskEvents';

/**
 * lastCounterLogEntry.ts — picks the most recent real log entry for a
 * counter's Undo affordance ("Logged +N · Undo" toast, R2 Counters UX
 * refresh — docs/SHARED_COUNTERS.md §Counters UX refresh → Amount logging).
 *
 * The platform Undo ops (web `undoLastCounterLog`, iOS
 * `AppDatabase+SharedCounters.undoLastCounterLog`) call this PURE selector
 * first to find which event to reverse, then do the actual write (tombstone
 * the event, subtract its `delta` from the source task's `currentCount`,
 * re-run the cross-board cascade). This module only picks the entry — it
 * never mutates anything.
 *
 * "Most recent" means the entry the user most recently MADE — ordered by
 * `createdAt` (write time), not `occurredAt`. Since the 2026-09-24 amendment
 * of WC Decision 1, a late log on an ended board is stamped at that board's
 * `endDate` (`lateLogOccurredAt`), in the past, so `occurredAt` no longer
 * tracks the order the user logged in: ordering by it would make Undo reverse
 * an earlier-made entry instead of the late log just made.
 */

/**
 * Selects the most-recent non-deleted `increment` event for a counter's
 * source task — the entry a fresh "Undo" tap reverses.
 *
 * Excludes the seed/backfill sentinel (`SEED_EVENT_OCCURRED_AT`): a
 * starting-count seed is not a "log" a user can undo. Ordered by `createdAt`
 * (the entry the user most recently made — a late log's `occurredAt` is
 * clamped into the past, see the module doc); ties (identical `createdAt`,
 * which can happen for rapid-fire logs sharing a millisecond) break on
 * `occurredAt`, so the selector is deterministic.
 *
 * @param events       Candidate events (typically the source task's full
 *   event set — filtering to `taskId`/`kind`/`isDeleted`/sentinel happens
 *   internally, so callers may pass an unfiltered array).
 * @param sourceTaskId The counter's source task id.
 * @returns The most recent qualifying event, or `null` if there is none
 *   (e.g. a brand-new counter, or one whose only event is its seed).
 */
export function selectLastIncrementEntry(
  events: TaskEvent[],
  sourceTaskId: string,
): TaskEvent | null {
  let best: TaskEvent | null = null;

  for (const event of events) {
    if (event.taskId !== sourceTaskId) continue;
    if (event.kind !== 'increment') continue;
    if (event.isDeleted) continue;
    if (event.occurredAt === SEED_EVENT_OCCURRED_AT) continue;

    if (best === null || isMoreRecent(event, best)) {
      best = event;
    }
  }

  return best;
}

/**
 * `true` iff `candidate` is more recent than `current`: `createdAt` (write
 * time) first, then `occurredAt` as the tie-break.
 *
 * @param candidate The event being considered.
 * @param current   The best event so far.
 * @returns Whether `candidate` should replace `current`.
 */
function isMoreRecent(candidate: TaskEvent, current: TaskEvent): boolean {
  const candidateCreated = new Date(candidate.createdAt).getTime();
  const currentCreated = new Date(current.createdAt).getTime();
  if (candidateCreated !== currentCreated) return candidateCreated > currentCreated;

  const candidateOccurred = new Date(candidate.occurredAt).getTime();
  const currentOccurred = new Date(current.occurredAt).getTime();
  return candidateOccurred > currentOccurred;
}
