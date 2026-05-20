import type { Task } from '../types/task';

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
 * Mirrored on iOS as `TasksTabViewModel.isTaskExpired(_:)`. Keep the
 * two implementations in lock-step; the predicate is small enough
 * that a divergence would surface as a per-platform filter mismatch
 * a user would notice on their next sync.
 *
 * @param task - Task row with `endDate` (and optional `timeframe`/`startDate`).
 * @param now - Reference time for the comparison. Defaults to
 *   `new Date()`; injected for deterministic tests.
 * @returns `true` iff the task carries an `endDate` < `now`.
 */
export function isTaskExpired(task: Task, now: Date = new Date()): boolean {
  if (!task.endDate) return false;
  const end = new Date(task.endDate).getTime();
  if (Number.isNaN(end)) return false;
  return now.getTime() > end;
}
