/**
 * Recurring board templates — Phase 6.2 (Preset-pool Recurring Boards)
 *
 * Pure functions over `RecurringBoardTemplate[]` + `Board[]` + `Task[]` that:
 *
 *   1. Detect which templates are pending a spawn for the current window
 *      (`findTemplatesPendingSpawn`). The Boards-tab `onAppear` hook calls
 *      this alongside Phase 6.1's `findPendingRecurringBoards`; templates
 *      spawn directly to the board list (no banner — locked design).
 *
 *   2. Validate that a template's pool is well-formed (`validateSpawnPool`).
 *      Returns a structured failure reason so the platform spawn driver
 *      can surface a "needs attention" indicator on the template row
 *      instead of silently failing.
 *
 *   3. Build the cell-by-cell placement of `Task | null` for a spawn
 *      (`buildSpawnPlacement`). Mirrors the wizard's `buildWizardPlacement`
 *      but driven by template config + pool, with optional RNG injection
 *      for deterministic tests.
 *
 * No persistence; no platform code; no side effects. The platform spawn
 * driver wraps the multi-table write (Board + BoardTasks + template
 * `lastSpawnedWindowKey` update) in a single transaction.
 *
 * Canonical design: docs/ARCHITECTURE.md §Phase 6.2.
 */

import { getCenterSquareIndex, isCenterAutoCompleted } from './centerSquare';
import { getTimeframeBoundaries, formatTimeframeLabel } from './calendarBoundaries';
import { fisherYatesShuffle } from './shuffle';
import { Timeframe, CenterSquareType } from '../constants/enums';
import type { Board } from '../types/board';
import type { Task } from '../types/task';
import type { RecurringBoardTemplate } from '../types/recurringBoardTemplate';
import type { WeekStartDay } from './calendarBoundaries';

/**
 * One pending template + the window it's pending for. The platform spawn
 * driver consumes this to drive a Board+BoardTasks insert plus a template
 * `lastSpawnedWindowKey` update inside a single transaction.
 */
export interface PendingTemplateSpawn {
  template: RecurringBoardTemplate;
  /** Local ISO8601 from `getTimeframeBoundaries()`. */
  windowStart: string;
  /** Local ISO8601 from `getTimeframeBoundaries()`. */
  windowEnd: string;
  /**
   * Default name to put on the spawned board (template.name + window label,
   * e.g. "Daily Workout — May 7, 2026"). The spawn driver may override.
   */
  suggestedName: string;
}

/**
 * Outcome of `validateSpawnPool`. The platform spawn driver branches on
 * `ok` — if `ok=false`, skip the spawn for this window AND surface the
 * `reason` via a "needs attention" indicator on the template's row in
 * the Profile recurring-templates list.
 */
export type SpawnPoolValidation =
  | { ok: true }
  | { ok: false; reason: SpawnPoolFailureReason };

export type SpawnPoolFailureReason =
  | 'pool_too_small'         // pool < fillable cells
  | 'has_deleted_tasks'      // any task in the resolved pool has isDeleted=true
  | 'unsupported_timeframe'  // template.timeframe === CUSTOM (form should prevent this)
  | 'unsupported_center';    // centerSquareType === CHOSEN (MVP excludes this)

/**
 * Counts the cells that need a Task placement for a given board configuration.
 * Even-sized boards have no center; odd-sized boards with FREE/CUSTOM_FREE
 * centers reserve one cell for the auto-completed free space; otherwise the
 * center cell gets a regular task.
 */
function fillableCellCount(
  boardSize: number,
  centerSquareType: CenterSquareType,
): number {
  const total = boardSize * boardSize;
  const centerIdx = getCenterSquareIndex(boardSize);
  const hasCenter = centerIdx >= 0;
  const centerOmitsTask = hasCenter && isCenterAutoCompleted(centerSquareType);
  return total - (centerOmitsTask ? 1 : 0);
}

/**
 * Detects templates pending a spawn for the current window.
 *
 * A template is pending when ALL of the following hold:
 *   - `!isDeleted` AND `isActive`.
 *   - `timeframe` is one of DAILY/WEEKLY/MONTHLY/YEARLY (CUSTOM excluded).
 *   - The current window's `startDate` (computed via `getTimeframeBoundaries`)
 *     differs from `lastSpawnedWindowKey` — i.e. we haven't spawned this
 *     window yet according to template state.
 *   - **Idempotency belt**: there is no existing non-deleted Board with
 *     `spawnedFromTemplateId === template.id` AND `startDate === windowStart`.
 *     This is the secondary check; it catches the rare case where
 *     `lastSpawnedWindowKey` lags behind reality (e.g., the previous spawn
 *     succeeded but the template-update step in the same txn was rolled
 *     back). With both checks, single-device idempotency is structurally
 *     guaranteed; the multi-device race remains an accepted MVP limitation.
 *
 * Output ordering is the input order — the caller may sort however it wants
 * (typically by `template.updatedAt desc` for UI display).
 *
 * @param templates - All non-deleted templates for the active user.
 * @param boards - All boards for the active user (used for the idempotency belt).
 * @param weekStartDay - Controls weekly window boundaries.
 * @param now - Reference date for window computation (typically `new Date()`).
 */
export function findTemplatesPendingSpawn(
  templates: RecurringBoardTemplate[],
  boards: Board[],
  weekStartDay: WeekStartDay,
  now: Date,
): PendingTemplateSpawn[] {
  const pending: PendingTemplateSpawn[] = [];

  for (const template of templates) {
    if (template.isDeleted) continue;
    if (!template.isActive) continue;
    if (template.timeframe === Timeframe.CUSTOM) continue;

    const { startDate, endDate } = getTimeframeBoundaries(
      template.timeframe,
      now,
      weekStartDay,
    );

    if (template.lastSpawnedWindowKey === startDate) continue;

    // Idempotency belt — see doc above.
    const alreadySpawned = boards.some(
      (b) =>
        !b.isDeleted &&
        b.spawnedFromTemplateId === template.id &&
        b.startDate === startDate,
    );
    if (alreadySpawned) continue;

    pending.push({
      template,
      windowStart: startDate,
      windowEnd: endDate,
      suggestedName: deriveSpawnedBoardName(template, startDate),
    });
  }

  return pending;
}

/**
 * Composes a default name for a spawned board: "<template name> — <window label>".
 * Used by `findTemplatesPendingSpawn`; the spawn driver may override.
 */
export function deriveSpawnedBoardName(
  template: RecurringBoardTemplate,
  windowStart: string,
): string {
  const trimmedName = template.name.trim();
  const windowLabel = formatTimeframeLabel(template.timeframe, windowStart);
  if (!trimmedName) return windowLabel;
  return `${trimmedName} — ${windowLabel}`;
}

/**
 * Validates a template's pool. The platform spawn driver passes the
 * resolved `poolTasks` (looked up from `seedTaskIds`); failures map to
 * user-facing "needs attention" copy on the template row.
 *
 * Pool semantics: `poolTasks.length >= fillableCellCount(...)`. The
 * spawn shuffles + slices to the cell count, so any extras become the
 * randomization pool. The earlier strict-fit `'all'` strategy was
 * dropped during the Phase 6.2 UX rework — it was just a special case
 * of the loose-fit semantics where the user happened to pick exactly
 * the cell count.
 *
 * @param template - The template being validated.
 * @param poolTasks - Resolved Tasks corresponding to `template.seedTaskIds`.
 *                    Caller is responsible for the lookup; order doesn't
 *                    matter (the spawn shuffles regardless).
 */
export function validateSpawnPool(
  template: RecurringBoardTemplate,
  poolTasks: Task[],
): SpawnPoolValidation {
  if (template.timeframe === Timeframe.CUSTOM) {
    return { ok: false, reason: 'unsupported_timeframe' };
  }
  if (template.centerSquareType === CenterSquareType.CHOSEN) {
    return { ok: false, reason: 'unsupported_center' };
  }
  if (poolTasks.some((t) => t.isDeleted)) {
    return { ok: false, reason: 'has_deleted_tasks' };
  }

  // Reject duplicate task ids in the resolved pool. The create/update
  // input schemas already reject duplicates at form-input time, but a
  // bad remote payload (e.g. an older client that didn't enforce
  // uniqueness, or a hand-crafted Firestore doc) could still slip
  // through. Without this guard `buildSpawnPlacement` would place the
  // same Task on multiple cells, contradicting the pool semantics.
  // We map this to `pool_too_small` because de-dup'd it IS too small —
  // surfacing a "needs attention" badge with that copy is closer to the
  // user-actionable story ("your pool has fewer unique tasks than this
  // board needs") than a separate `pool_has_duplicates` reason would be.
  const uniqueIds = new Set(poolTasks.map((t) => t.id));
  if (uniqueIds.size !== poolTasks.length) {
    return { ok: false, reason: 'pool_too_small' };
  }

  const required = fillableCellCount(
    template.boardSize,
    template.centerSquareType,
  );
  if (poolTasks.length < required) {
    return { ok: false, reason: 'pool_too_small' };
  }
  return { ok: true };
}

export interface BuildSpawnPlacementArgs {
  template: RecurringBoardTemplate;
  /**
   * Resolved pool. Caller must have already filtered out soft-deleted tasks
   * AND validated the pool size via `validateSpawnPool`. Behavior is
   * undefined when called with an invalid pool — defensive callers should
   * branch on `validateSpawnPool` first.
   */
  poolTasks: Task[];
  /**
   * Optional uniform `[0, 1)` RNG override. Default: `Math.random` via
   * `fisherYatesShuffle`. Tests pass a seeded RNG to make placement
   * deterministic.
   */
  rng?: () => number;
}

/**
 * Builds the cell-by-cell placement for a spawn. Returns an array of
 * length `boardSize²` where each entry is a `Task` to place on that
 * cell, or `null` for the auto-completed FREE / CUSTOM_FREE center on
 * odd-sized boards.
 *
 * Placement order:
 *   1. If `template.isRandomized`, shuffle the pool via
 *      `fisherYatesShuffle(rng)`. Otherwise preserve `seedTaskIds` order.
 *   2. Slice to the fillable cell count (ignoring extras — that's the
 *      whole point of the loose-fit pool).
 *   3. Walk cells 0..boardSize²-1 left-to-right, top-to-bottom. At the
 *      center cell (odd boards only), if FREE/CUSTOM_FREE, leave `null`;
 *      otherwise place the next pool task.
 */
export function buildSpawnPlacement(
  args: BuildSpawnPlacementArgs,
): (Task | null)[] {
  const { template, poolTasks, rng } = args;
  const total = template.boardSize * template.boardSize;
  const centerIdx = getCenterSquareIndex(template.boardSize);
  const hasCenter = centerIdx >= 0;
  const centerOmitsTask =
    hasCenter && isCenterAutoCompleted(template.centerSquareType);

  const fillCount = fillableCellCount(
    template.boardSize,
    template.centerSquareType,
  );
  const ordered = template.isRandomized
    ? fisherYatesShuffle(poolTasks, rng)
    : poolTasks;
  const placed = ordered.slice(0, fillCount);

  const placement: (Task | null)[] = new Array(total).fill(null);
  let nextTaskIdx = 0;
  for (let cell = 0; cell < total; cell++) {
    if (cell === centerIdx && centerOmitsTask) continue;
    placement[cell] = placed[nextTaskIdx] ?? null;
    nextTaskIdx++;
  }
  return placement;
}
