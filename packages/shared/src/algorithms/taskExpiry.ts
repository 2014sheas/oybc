import type { Task } from '../types/task';

const DATE_ONLY_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;

/**
 * Parse the supported `Task.endDate` shapes into a comparable `Date`.
 *
 * Accepted shapes:
 *   - Calendar-only `YYYY-MM-DD` → interpreted as **local end-of-day**
 *     (`23:59:59.999` in the device's local timezone). Distinct from
 *     `new Date('YYYY-MM-DD')`, which would parse to UTC midnight and
 *     expire the task up to a day early for users east of UTC.
 *   - Local-ISO without timezone, written by `toLocalISO()` in
 *     `calendarBoundaries.ts` (e.g. `2026-05-25T23:59:59.999`).
 *     `new Date(...)` parses this in local time, which is what we want.
 *   - Full ISO8601 with `Z` / `+HH:MM` offset, which Firestore writes
 *     during sync round-trips.
 *
 * Returns `null` for unparseable strings; callers treat that as
 * "indefinite" (matches the "missing endDate" branch).
 */
function parseTaskEndDate(s: string): Date | null {
  const dateOnly = s.match(DATE_ONLY_PATTERN);
  if (dateOnly) {
    const [, y, mo, d] = dateOnly;
    return new Date(Number(y), Number(mo) - 1, Number(d), 23, 59, 59, 999);
  }
  const parsed = new Date(s);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed;
}

/**
 * Phase 6.Y — Timeboxed Tasks.
 *
 * Returns `true` when the task has an `endDate` AND that date has
 * passed. "Indefinite" tasks (no `endDate` set, which today implies
 * also no `timeframe`/`startDate`) are never expired.
 *
 * Used by:
 *   - The Tasks-tab default filter (hides expired tasks unless the
 *     "Show expired" toggle is on).
 *   - Future cross-board cleanup affordances (e.g., "archive all
 *     expired tasks").
 *
 * Date shapes supported (see {@link parseTaskEndDate}): `YYYY-MM-DD`
 * (local end-of-day), local-ISO without timezone (`toLocalISO()`), and
 * full ISO8601 with `Z` or offset suffix. The Dexie/GRDB backfill
 * migrations write the same shape the source `Board.endDate` carries,
 * which is local-ISO today — but the schema is loose enough that the
 * predicate must remain robust across all three.
 *
 * Mirrored on iOS as `TasksTabViewModel.isTaskExpired(_:)`. Keep the
 * two implementations in lock-step; the predicate is small enough
 * that a divergence would surface as a per-platform filter mismatch
 * a user would notice on their next sync.
 *
 * @param task - Task row with `endDate` (and optional `timeframe`/`startDate`).
 * @param now - Reference time for the comparison. Defaults to
 *   `new Date()`; injected for deterministic tests.
 * @returns `true` iff the task carries a parseable `endDate` < `now`.
 */
export function isTaskExpired(task: Task, now: Date = new Date()): boolean {
  if (!task.endDate) return false;
  const end = parseTaskEndDate(task.endDate);
  if (end === null) return false;
  return now.getTime() > end.getTime();
}
