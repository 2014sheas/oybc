/**
 * Pure routing/name helpers for `BoardPlaySurface`'s shared-counting-square
 * touchpoints (Counters Refresh R3 — board-play). Extracted so the
 * "which source task + which amount does this tap apply to" and "what name
 * does the credited toast show" seams are unit-testable without a DOM or a
 * live Dexie transaction (mirrors the `boardPlayFlash.ts` precedent).
 */
import { formatCounterName, type Task } from '@oybc/shared';

/**
 * Resolves the shared-counter SOURCE task id for a given task, or `null`
 * when the task isn't part of any shared-counter group.
 *
 * A LINKED (derived) task points at its source via `sharedCounterId`; a
 * SOURCE task is its own id, discoverable via membership in
 * `sharedCounterSourceIds` (built by `useBoardPlayData`, includes P5
 * zero-link promoted counters). Callers (grid tap / detail modal / context
 * menu) all resolve routing through this single function so the three
 * touchpoints can never drift on which id "shared counting square" tapping
 * increments/decrements.
 *
 * @param task - The tapped/opened task.
 * @param sharedCounterSourceIds - Task ids that are shared-counter SOURCES
 *   (from `useBoardPlayData`).
 */
export function resolveSharedCounterSourceId(
  task: Task,
  sharedCounterSourceIds: Set<string>,
): string | null {
  if (task.sharedCounterId != null) return task.sharedCounterId;
  if (sharedCounterSourceIds.has(task.id)) return task.id;
  return null;
}

/**
 * Resolves the amount a plain one-tap log should use for a shared counting
 * square — the source's persisted `defaultLogAmount`, or `1` when unset
 * (R3 — "was hardcoded 1").
 *
 * @param sourceTask - The shared counter's source Task (may be undefined if
 *   the workspace task map hasn't resolved it yet — defensive fallback).
 */
export function resolveSharedCounterDefaultAmount(sourceTask: Task | undefined): number {
  return sourceTask?.defaultLogAmount ?? 1;
}

/**
 * Resolves a counter's display name for the board-play credited toast —
 * pair-derived via `formatCounterName(action, unit)`, falling back to the
 * stored title. Matches the established fallback order used by
 * `sharedCounterGroups.ts` / `linkableCounter.ts` / `useCounterArrivals`'s
 * `counterDisplayName` (R3 copy contract: NEVER raw `task.title` alone as
 * the primary source for a COUNTER name).
 *
 * @param sourceTask - The shared counter's source Task.
 */
export function resolveCreditedCounterName(sourceTask: Task | undefined): string {
  if (!sourceTask) return '';
  return formatCounterName(sourceTask.action, sourceTask.unit) || sourceTask.title || '';
}
