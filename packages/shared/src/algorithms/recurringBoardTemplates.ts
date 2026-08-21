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

import { placeBoard, fillableCellCount, CenterSquareType, type BoardSize } from '@oybc/bingo-core';
import { getTimeframeBoundaries, formatTimeframeLabel } from './calendarBoundaries';
import { Timeframe } from '../constants/enums';
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

// `fillableCellCount` now lives in @oybc/bingo-core (imported above) — the
// same primitive drives the wizard, the spawn path, and Play's server-side
// board fan-out. Kept as a plain re-import here (not re-exported) so existing
// `recurringBoardTemplates` callers see no change.

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
 * cell, or `null` for the auto-completed FREE center on
 * odd-sized boards.
 *
 * Thin wrapper over the shared `placeBoard` core (@oybc/bingo-core):
 * resolves the template's geometry / randomization / pool ordering, then
 * delegates the cell walk. The spawn path never pins a CHOSEN center
 * (`validateSpawnPool` rejects CHOSEN templates), so no `chosenCenterId`
 * is passed — a CHOSEN center that slipped through is treated as ordinary,
 * exactly as the old hand-rolled loop did.
 */
export function buildSpawnPlacement(
  args: BuildSpawnPlacementArgs,
): (Task | null)[] {
  const { template, poolTasks, rng } = args;
  return placeBoard({
    items: poolTasks,
    gridSize: template.boardSize,
    centerType: template.centerSquareType,
    randomize: template.isRandomized,
    rng,
  });
}

/**
 * Result of {@link buildRepeatBoardTemplateInput} — everything the
 * "Repeat this board…" write (docs/POOLS_RECURRING.md §Surfaces item 7)
 * needs to insert a new `RecurringBoardTemplate` directly (NOT via
 * `createRecurringBoardTemplate`, which always starts
 * `lastSpawnedWindowKey: null` — this record is born with it already set,
 * see the field doc below for why).
 */
export interface RepeatBoardTemplateInput {
  name: string;
  timeframe: Timeframe; // the CHOSEN cadence, not board.timeframe
  boardSize: BoardSize;
  centerSquareType: CenterSquareType;
  isRandomized: boolean;
  manualTaskIds: string[];
  isActive: true;
  /**
   * Pre-seeded to the CADENCE's window containing the board's start date —
   * critically NOT the board's own timeframe's window. The existing board
   * IS this window's spawn; setting this up front (rather than leaving it
   * `null`) is precisely what stops `findTemplatesPendingSpawn` from
   * generating a duplicate spawn for the same window the very next time
   * the Boards tab opens.
   */
  lastSpawnedWindowKey: string;
  /** Decode-compat snapshot — always equals `manualTaskIds` for a
   *  repeat-this-board record (there is no pool to seed from). */
  seedTaskIds: string[];
  poolIds: string[];
  removedTaskIds: string[];
}

/**
 * Builds the `RecurringBoardTemplate` insert payload for "Repeat this
 * board…" (docs/POOLS_RECURRING.md §Surfaces item 7): a one-off board
 * gaining a repeat cadence AFTER the fact, with its current placed tasks as
 * the record's entire (manual-only, zero-pool) mix.
 *
 * `lastSpawnedWindowKey` is computed from `cadence` — the newly-chosen
 * repeat cadence — evaluated against the board's OWN `startDate`, never
 * from `board.timeframe`. A one-off Tuesday DAILY board repeated Weekly
 * must key off that Tuesday's WEEK window, not the day: using the board's
 * timeframe here would produce a window key for the wrong granularity,
 * and the next `findTemplatesPendingSpawn` check would see a mismatched
 * (or already-elapsed) window and spawn a duplicate board mid-window.
 *
 * No persistence; no id/timestamps — the caller (`repeatBoardAsRecurring`)
 * fills those in as part of a single atomic write that also back-stamps
 * the source board's `spawnedFromTemplateId`.
 *
 * @param board - The source one-off board. Only `name`/`boardSize`/
 *   `centerSquareType`/`isRandomized`/`startDate` are read.
 * @param boardTaskIds - Caller-resolved: distinct, non-deleted, non-FREE-
 *   center task ids currently placed on the board (in placement order).
 * @param cadence - The newly-chosen repeat cadence (DAILY/WEEKLY/MONTHLY/
 *   YEARLY — never CUSTOM, which the picker excludes).
 * @param weekStartDay - Only relevant when `cadence === WEEKLY`.
 */
export function buildRepeatBoardTemplateInput(
  board: {
    name: string;
    boardSize: BoardSize;
    centerSquareType: CenterSquareType;
    isRandomized: boolean;
    startDate: string;
  },
  boardTaskIds: string[],
  cadence: Timeframe,
  weekStartDay: WeekStartDay,
): RepeatBoardTemplateInput {
  const { startDate: lastSpawnedWindowKey } = getTimeframeBoundaries(
    cadence,
    new Date(board.startDate),
    weekStartDay,
  );

  return {
    name: board.name,
    timeframe: cadence,
    boardSize: board.boardSize,
    centerSquareType: board.centerSquareType,
    isRandomized: board.isRandomized,
    manualTaskIds: [...boardTaskIds],
    isActive: true,
    lastSpawnedWindowKey,
    seedTaskIds: [...boardTaskIds],
    poolIds: [],
    removedTaskIds: [],
  };
}
