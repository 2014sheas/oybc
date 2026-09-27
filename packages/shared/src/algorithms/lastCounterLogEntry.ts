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

/**
 * The closed board a late log was made on — the fields
 * {@link selectClosedBoardLateLogs} reads.
 */
export interface ClosedBoardLateLogBoard {
  /** The board's id (a late log's `boardId` provenance). */
  id: string;
  /** Window end; a late log is stamped exactly at this instant. */
  endDate?: string | null;
  /** When the board closed; a late log is CREATED after this instant. */
  sealedAt?: string | null;
}

/**
 * Selects the late logs a user made directly on a CLOSED board for one task,
 * newest first (Board Edit redesign slice 4, D10 / owner ruling R2 — a late
 * log is undoable, and only a late log).
 *
 * A late log is identified by provenance + timestamps, never a marker field:
 * non-deleted, `taskId` matches, `boardId === board.id`, `occurredAt` is the
 * board's `endDate` INSTANT (parsed compare — the late-log path re-encodes the
 * local-ISO `endDate` as UTC), and `createdAt` is strictly after `sealedAt`.
 * Any kind (`completion` or `increment`). Ordered by `createdAt` descending
 * (the entry the user most recently made — the one "Undo late log" reverses),
 * ties broken by `id` descending so the pick is deterministic.
 *
 * An unsealed board, or one with no parseable `endDate` / `sealedAt`, has no
 * late logs (`[]`).
 *
 * @param events Candidate events (may be unfiltered — filtering is internal).
 * @param board  The closed board (`id`, `endDate`, `sealedAt`).
 * @param taskId The task whose late logs to select (for a window-stamped
 *   derived square, the ROOT counter — derived rows own no events).
 * @returns The qualifying events, newest `createdAt` first.
 */
export function selectClosedBoardLateLogs(
  events: ReadonlyArray<TaskEvent>,
  board: ClosedBoardLateLogBoard,
  taskId: string,
): TaskEvent[] {
  if (board.sealedAt == null || board.endDate == null) return [];
  const endMs = new Date(board.endDate).getTime();
  const sealedMs = new Date(board.sealedAt).getTime();
  if (Number.isNaN(endMs) || Number.isNaN(sealedMs)) return [];

  const lateLogs = events.filter(
    (e) =>
      !e.isDeleted &&
      e.taskId === taskId &&
      e.boardId === board.id &&
      new Date(e.occurredAt).getTime() === endMs &&
      new Date(e.createdAt).getTime() > sealedMs,
  );
  return lateLogs.sort((a, b) => {
    const byCreated = new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime();
    if (byCreated !== 0) return byCreated;
    return a.id < b.id ? 1 : a.id > b.id ? -1 : 0;
  });
}
