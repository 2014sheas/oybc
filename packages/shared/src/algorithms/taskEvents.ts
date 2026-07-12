import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { TaskType } from '../constants/enums';

/**
 * Windowed Completion — pure evaluation helpers
 * (docs/WINDOWED_COMPLETION.md §Semantics per task type + §Sealing).
 *
 * These functions are the shared kernel that PR B (write paths / grids /
 * derivation) and PR C (sealing) build on. Nothing here has platform
 * dependencies — the iOS twin mirrors it verbatim.
 */

/** 48h cap on the auto-seal backstop (docs §Sealing → backstop table). */
export const BACKSTOP_MAX_MS = 48 * 60 * 60 * 1000;

/**
 * The result of resolving a task's state within a window: whether the square
 * is complete, and the windowed count (0 for normal tasks).
 */
export interface TaskWindowState {
  isCompleted: boolean;
  count: number;
}

/**
 * Context threaded through windowed compound evaluation (docs §Semantics —
 * "evaluateCompound gains a window-context parameter"). When present, primitive
 * children resolve against `windowStart` via {@link resolveTaskWindowState};
 * derived-counting children fall back to their lifetime cache (the carve-out);
 * nested compounds inherit the SAME `windowStart` (host-window inheritance).
 */
export interface CompoundWindowContext {
  /** Window lower bound (`board.startDate`), or `null` for lifetime. */
  windowStart: string | null;
  /** This workspace's non-deleted TaskEvents grouped by `taskId`. */
  eventsByTaskId: Record<string, TaskEvent[]>;
}

/**
 * Context passed to `computeBoardStatsUpdate` to switch it from lifetime
 * (today's behavior) to windowed evaluation. The board supplies its own
 * `startDate` as the window lower bound — the caller only provides the
 * grouped events.
 */
export interface WindowEvaluationContext {
  /** This workspace's non-deleted TaskEvents grouped by `taskId`. */
  eventsByTaskId: Record<string, TaskEvent[]>;
}

/**
 * Whether a Task **owns its completion state** as events (docs §New entity +
 * §Derived-task carve-out). Only event-owning tasks may have `TaskEvent` rows;
 * the write choke points call this before appending an event, and backfill
 * skips non-owning tasks.
 *
 *   - `NORMAL` → owns events.
 *   - `COUNTING` with no `sharedCounterId` (plain / source) → owns events.
 *   - `COUNTING` with `sharedCounterId` (derived) → does NOT (source-driven).
 *   - `COMPOUND` / `ACHIEVEMENT` → do NOT (derived from children / board state).
 *
 * @param task Minimal task shape (type + shared-counter link).
 * @returns `true` iff the task owns its state via events.
 */
export function isEventOwningTask(
  task: Pick<Task, 'type' | 'sharedCounterId'>,
): boolean {
  if (task.type === TaskType.NORMAL) return true;
  if (task.type === TaskType.COUNTING) {
    return task.sharedCounterId == null;
  }
  return false;
}

/**
 * Resolve an event-owning task's state within a window (docs §Semantics).
 *
 * Callers MUST branch derived / compound / achievement tasks BEFORE calling —
 * this function only handles `NORMAL` and plain / source `COUNTING`. Events are
 * filtered to non-deleted defensively (a tombstoned event never counts), so a
 * `tombstoned` vector resolves the same whether or not the caller pre-filtered.
 *
 * Window semantics have a **start bound only** (`[windowStart, ∞)`); the upper
 * bound is enforced by sealing, not filtering. `windowStart = null` means
 * lifetime (library surfaces, indefinite semantics) — every event counts.
 * Comparison is a parsed timestamp compare (`occurredAt >= windowStart`), never
 * string equality, to stay robust to local-ISO vs UTC-`Z` encodings.
 *
 * @param task        The event-owning task (normal or plain/source counting).
 * @param events      This task's events (deleted rows ignored internally).
 * @param windowStart Window lower bound, or `null` for lifetime.
 * @returns `{ isCompleted, count }`. For counting, `count` is the low-clamped
 *          window sum (overshoot preserved — never high-clamped). For normal,
 *          `count` is the number of in-window completion events.
 */
export function resolveTaskWindowState(
  task: Task,
  events: TaskEvent[],
  windowStart: string | null,
): TaskWindowState {
  const lowerMs = windowStart == null ? null : new Date(windowStart).getTime();
  const inWindow = (e: TaskEvent): boolean => {
    if (e.isDeleted) return false;
    if (lowerMs === null) return true;
    return new Date(e.occurredAt).getTime() >= lowerMs;
  };

  if (task.type === TaskType.COUNTING) {
    let sum = 0;
    for (const e of events) {
      if (e.kind !== 'increment') continue;
      if (!inWindow(e)) continue;
      sum += e.delta ?? 0;
    }
    // Low-end clamp only — overshoot invariant preserved (never high-clamped).
    const count = Math.max(0, sum);
    const isCompleted = task.maxCount != null && count >= task.maxCount;
    return { isCompleted, count };
  }

  // NORMAL (and any defensive non-counting caller): complete iff a non-deleted
  // completion event falls in the window.
  let completions = 0;
  for (const e of events) {
    if (e.kind !== 'completion') continue;
    if (!inWindow(e)) continue;
    completions += 1;
  }
  return { isCompleted: completions > 0, count: completions };
}

/**
 * The auto-seal backstop **duration** for a board's window (docs §Sealing):
 * `min(48h, windowLength/4)`. Timeframe-scaling falls out of the window length
 * itself — daily → 6h, weekly → 42h, monthly/yearly/custom≥8d → 48h — so one
 * formula owns every timeframe.
 *
 * @param startDate Board window start (ISO8601).
 * @param endDate   Board window end (ISO8601).
 * @returns Backstop duration in ms, capped at 48h and floored at 0.
 */
export function backstopWindowMs(startDate: string, endDate: string): number {
  const lengthMs = new Date(endDate).getTime() - new Date(startDate).getTime();
  return Math.min(BACKSTOP_MAX_MS, Math.max(0, lengthMs) / 4);
}

/**
 * The absolute auto-seal deadline for a board, as epoch ms (docs §Sealing →
 * "deadline keys off `max(endDate, activatedAt)`"). Returning ms — rather than
 * an ISO string — sidesteps the local-ISO vs UTC encoding decision; callers
 * compare `now.getTime() > deadline`.
 *
 * A draft activated AFTER its window already expired keys off `activatedAt`, so
 * it still gets one full prompt cycle instead of an instant silent seal.
 * Indefinite boards (no `endDate`) never seal → `null`.
 *
 * @param startDate   Board window start (ISO8601).
 * @param endDate     Board window end (ISO8601), or null/undefined for indefinite.
 * @param activatedAt When the board was activated (ISO8601), if known.
 * @returns Epoch-ms deadline, or `null` when the board never seals.
 */
export function computeBackstopDeadlineMs(
  startDate: string,
  endDate: string | null | undefined,
  activatedAt?: string | null,
): number | null {
  if (endDate == null) return null;
  const endMs = new Date(endDate).getTime();
  const activatedMs = activatedAt != null ? new Date(activatedAt).getTime() : endMs;
  const anchor = Math.max(endMs, activatedMs);
  return anchor + backstopWindowMs(startDate, endDate);
}
