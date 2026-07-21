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
 */

/**
 * Selects the most-recent non-deleted `increment` event for a counter's
 * source task — the entry a fresh "Undo" tap reverses.
 *
 * Excludes the seed/backfill sentinel (`SEED_EVENT_OCCURRED_AT`): a
 * starting-count seed is not a "log" a user can undo. Ties (identical
 * `occurredAt`, which can happen for rapid-fire logs sharing a millisecond)
 * break on `createdAt`, so the selector is deterministic even when two
 * events share the same semantic timestamp.
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

/** `true` iff `candidate` is more recent than `current` (occurredAt, then createdAt tie-break). */
function isMoreRecent(candidate: TaskEvent, current: TaskEvent): boolean {
  const candidateOccurred = new Date(candidate.occurredAt).getTime();
  const currentOccurred = new Date(current.occurredAt).getTime();
  if (candidateOccurred !== currentOccurred) return candidateOccurred > currentOccurred;

  const candidateCreated = new Date(candidate.createdAt).getTime();
  const currentCreated = new Date(current.createdAt).getTime();
  return candidateCreated > currentCreated;
}
