/**
 * Recurring boards — Phase 6.1 (Timeframe-Prompted)
 *
 * Pure functions over the local `boards` table + `UserPreferences` that:
 *   1. Detect which recurring board windows are pending (no board exists for
 *      the current daily/weekly/monthly/yearly window with the corresponding
 *      pref enabled). Surfaced via the Boards-tab banner on app open.
 *   2. Find currently-active longer-window "parent" boards for a given child
 *      timeframe. Used by the wizard's "From parent boards" filter to surface
 *      candidate tasks the user can place on the new (child) board — the same
 *      Task is shared across both placements (global per-Task completion).
 *
 * No persistence; no platform code; no side effects. Both functions recompute
 * from scratch on each call — banner reactivity comes from the platform-side
 * useLiveQuery / observed-store wrappers, not from any cache here.
 *
 * Canonical design: docs/ARCHITECTURE.md §Phase 6.
 */

import {
  formatTimeframeLabel,
  getTimeframeBoundaries,
  isWithinTimeframe,
} from './calendarBoundaries';
import { BoardStatus, CenterSquareType, Timeframe } from '../constants/enums';
import type { BoardSize } from '@oybc/bingo-core';
import type { Board } from '../types/board';
import type { UserPreferences } from '../types/user';

/**
 * Hierarchy of which timeframes "contain" which other timeframes for the
 * purpose of parent-child task derivation. A daily board's parents are the
 * currently-active weekly/monthly/yearly boards; a yearly board has none.
 *
 * `Timeframe.CUSTOM` is intentionally empty for Phase 1 — custom boards have
 * user-specified dates rather than computed boundaries, so they don't fit the
 * recurrence machinery. Re-evaluate if Phase 2+ introduces custom recurrence.
 */
export const PARENT_TIMEFRAMES: Record<Timeframe, Timeframe[]> = {
  [Timeframe.DAILY]: [Timeframe.WEEKLY, Timeframe.MONTHLY, Timeframe.YEARLY],
  [Timeframe.WEEKLY]: [Timeframe.MONTHLY, Timeframe.YEARLY],
  [Timeframe.MONTHLY]: [Timeframe.YEARLY],
  [Timeframe.YEARLY]: [],
  [Timeframe.CUSTOM]: [],
  [Timeframe.INDEFINITE]: [],
};

/**
 * The four recurring timeframes Phase 1 supports, in **longest-window-first
 * order** so banner consumers can render directly without re-sorting. The
 * order is load-bearing: creating parents before children means the wizard's
 * "From parent boards" filter has something to surface for the daily board.
 */
const RECURRING_TIMEFRAMES_BY_WINDOW_DESC: Timeframe[] = [
  Timeframe.YEARLY,
  Timeframe.MONTHLY,
  Timeframe.WEEKLY,
  Timeframe.DAILY,
];

/**
 * Same set, inverted — used by `getCoreBoardSlots` so the persistent
 * Core Boards section on the home screen reads top-to-bottom as
 * daily → weekly → monthly → yearly. Shortest-first is what the user
 * acts on most often, so it sits at the top.
 */
const RECURRING_TIMEFRAMES_BY_WINDOW_ASC: Timeframe[] = [
  Timeframe.DAILY,
  Timeframe.WEEKLY,
  Timeframe.MONTHLY,
  Timeframe.YEARLY,
];

/**
 * One row of the Boards-tab "pending boards" banner. Carries everything the
 * banner needs to render the row + everything the wizard needs to be
 * prefilled when the user taps "Create".
 */
export interface PendingRecurringBoard {
  timeframe: Timeframe;
  /** Local ISO8601 from `getTimeframeBoundaries()` — bit-for-bit comparable. */
  startDate: string;
  /** Local ISO8601 from `getTimeframeBoundaries()`. */
  endDate: string;
  /** Human-readable label from `formatTimeframeLabel()` (e.g. "Today", "May 2026"). */
  suggestedName: string;
}

/**
 * Returns whether a `UserPreferences`'s `recurring${T}Enabled` flag is true.
 * Returning false for `CUSTOM` is intentional — custom is excluded from
 * Phase 1 recurrence (see `PARENT_TIMEFRAMES` doc).
 */
function isRecurringTimeframeEnabled(
  prefs: UserPreferences,
  timeframe: Timeframe
): boolean {
  switch (timeframe) {
    case Timeframe.DAILY:
      return prefs.recurringDailyEnabled;
    case Timeframe.WEEKLY:
      return prefs.recurringWeeklyEnabled;
    case Timeframe.MONTHLY:
      return prefs.recurringMonthlyEnabled;
    case Timeframe.YEARLY:
      return prefs.recurringYearlyEnabled;
    case Timeframe.CUSTOM:
    case Timeframe.INDEFINITE:
      return false;
  }
}

/**
 * Finds the recurring-board windows the user should be prompted to create.
 *
 * Returns one `PendingRecurringBoard` for every enabled timeframe whose
 * current window has **no** corresponding non-deleted `Board` in `boards`.
 * Output is **longest-window-first** (yearly → monthly → weekly → daily) so
 * the banner renders parents above children.
 *
 * Match condition: `b.timeframe === T` AND `!b.isDeleted` AND
 * `b.startDate === getTimeframeBoundaries(T, now, prefs.weekStartDay).startDate`.
 * String equality is safe because both sides come from the same `toLocalISO()`
 * formatter — bit-for-bit identical for the same calendar window.
 *
 * @param boards - All boards belonging to the active user (caller filters by userId).
 * @param prefs - User preferences. `weekStartDay` controls weekly boundaries.
 * @param now - Reference date for window computation. Caller passes `new Date()`
 *              for live use; tests pass a frozen date.
 *
 * @example
 * findPendingRecurringBoards(allBoards, prefs, new Date('2026-01-01T08:00'))
 * // → [{ timeframe: YEARLY, ... }, { timeframe: MONTHLY, ... },
 * //    { timeframe: WEEKLY, ... }, { timeframe: DAILY, ... }]
 */
export function findPendingRecurringBoards(
  boards: Board[],
  prefs: UserPreferences,
  now: Date
): PendingRecurringBoard[] {
  const pending: PendingRecurringBoard[] = [];

  for (const timeframe of RECURRING_TIMEFRAMES_BY_WINDOW_DESC) {
    if (!isRecurringTimeframeEnabled(prefs, timeframe)) continue;

    const { startDate, endDate } = getTimeframeBoundaries(
      timeframe,
      now,
      prefs.weekStartDay
    );

    // Only a *core* board for the window dismisses the banner. Manual
    // ad-hoc boards (same timeframe + same window, isCore = false) are
    // unrelated to the recurring suggestion and must NOT silently
    // suppress it. A board is core iff it was created from the
    // recurring banner (Phase 6.1) or auto-spawned from a
    // RecurringBoardTemplate (Phase 6.2). See `Board.isCore`.
    const exists = boards.some(
      (b) =>
        b.timeframe === timeframe &&
        !b.isDeleted &&
        b.startDate === startDate &&
        b.isCore === true
    );
    if (exists) continue;

    pending.push({
      timeframe,
      startDate,
      endDate,
      suggestedName: formatTimeframeLabel(timeframe, startDate),
    });
  }

  return pending;
}

/**
 * Persistent home-screen "Core Boards" section data — returns one entry
 * per *enabled* recurring timeframe, in shortest-window-first order
 * (daily → weekly → monthly → yearly), with the matched core board
 * attached when one exists for the current window.
 *
 * Distinct from {@link findPendingRecurringBoards}: that helper only
 * returns timeframes that NEED creation. This one always returns every
 * enabled timeframe, with `currentBoard === null` indicating the
 * not-yet state. The Boards-tab section uses this so the per-timeframe
 * Core Board Browser is always reachable from the home screen, not
 * just when something needs creating.
 *
 * `currentBoard` matching uses the same string-equal predicate as
 * `findPendingRecurringBoards`: `timeframe === T && !isDeleted &&
 * startDate === computedStart && isCore === true`. Returns the matched
 * `Board` (the first match if multiple exist — which shouldn't happen
 * but is harmless if it does).
 *
 * Returns `[]` when no recurring timeframes are enabled at all — the
 * section then unmounts.
 *
 * @param boards - All boards belonging to the active user.
 * @param prefs - User preferences (the `recurring${T}Enabled` flags + `weekStartDay`).
 * @param now - Reference date for window computation.
 */
export interface CoreBoardSlot {
  timeframe: Timeframe;
  /** Local ISO8601 from `getTimeframeBoundaries()`. */
  windowStart: string;
  /** Local ISO8601 from `getTimeframeBoundaries()`. */
  windowEnd: string;
  /** Human-readable label (e.g. "Today", "Week of May 18 – 24, 2026"). */
  windowLabel: string;
  /** The matched core board for the current window, or null if none exists. */
  currentBoard: Board | null;
}

export function getCoreBoardSlots(
  boards: Board[],
  prefs: UserPreferences,
  now: Date,
): CoreBoardSlot[] {
  const slots: CoreBoardSlot[] = [];

  for (const timeframe of RECURRING_TIMEFRAMES_BY_WINDOW_ASC) {
    if (!isRecurringTimeframeEnabled(prefs, timeframe)) continue;

    const { startDate, endDate } = getTimeframeBoundaries(
      timeframe,
      now,
      prefs.weekStartDay,
    );

    const match = boards.find(
      (b) =>
        b.timeframe === timeframe &&
        !b.isDeleted &&
        b.startDate === startDate &&
        b.isCore === true,
    );

    slots.push({
      timeframe,
      windowStart: startDate,
      windowEnd: endDate,
      windowLabel: formatTimeframeLabel(timeframe, startDate),
      currentBoard: match ?? null,
    });
  }

  return slots;
}

/**
 * Returns the currently-active longer-window "parent" boards for a given
 * child timeframe. Used by the wizard's "From parent boards" filter to
 * surface candidate tasks the user can place on the new child board.
 *
 * "Currently-active" means: status is ACTIVE, not deleted, and `now` falls
 * within the board's `[startDate, endDate]` window. A board whose timeframe
 * matches but whose window has expired (e.g. last month's monthly when the
 * caller is creating today's daily) is excluded — it's not a useful source
 * of tasks for the new child.
 *
 * Returns an empty array for `Timeframe.YEARLY` (no parents) and for
 * `Timeframe.CUSTOM` (excluded from Phase 1 recurrence). The wizard's
 * empty-state UI handles the empty result.
 *
 * Note: the design doc (ARCHITECTURE.md §Phase 6.1 algorithms) sketches a
 * `weekStartDay` parameter on this function. It turns out to be unused in
 * practice — the window check (`isWithinTimeframe`) operates on the
 * already-stored `startDate`/`endDate` strings on each board, never recomputes
 * them. The doc is being followed up in a separate touch-up PR.
 *
 * @param childTimeframe - The timeframe of the board being created.
 * @param allActiveBoards - Boards to filter. Caller scopes by userId.
 * @param now - Reference date for "currently active" check.
 */
export function getParentBoards(
  childTimeframe: Timeframe,
  allActiveBoards: Board[],
  now: Date
): Board[] {
  const parentTimeframes = PARENT_TIMEFRAMES[childTimeframe];
  if (parentTimeframes.length === 0) return [];

  const parentSet = new Set(parentTimeframes);
  return allActiveBoards.filter(
    (b) =>
      parentSet.has(b.timeframe) &&
      !b.isDeleted &&
      b.status === BoardStatus.ACTIVE &&
      isWithinTimeframe(now, b.startDate, b.endDate)
  );
}

/**
 * True when a board is still in its "just dealt" state — zero **user**
 * completions, where the auto-completed FREE center (odd board + FREE
 * center only) doesn't count against that (docs/POOLS_RECURRING.md
 * §Behavior invariants — "↻ Deal again" + the P6 spawn-provenance note
 * share this gate).
 *
 * The FREE center auto-fills at spawn via the derivation pass (see
 * `computeBoardStatsUpdate`), so a fresh odd+FREE board's
 * `completedTasks` starts at 1, not 0. This function accounts for that
 * baseline rather than hard-coding a magic "1" everywhere a caller needs
 * to ask "has the user touched this board yet."
 *
 * @param board - Only `completedTasks`/`boardSize`/`centerSquareType` are read.
 */
export function isFreshlyDealtBoard(board: {
  completedTasks: number;
  boardSize: BoardSize;
  centerSquareType: CenterSquareType;
}): boolean {
  const hasFreeCenterAutoComplete =
    board.boardSize % 2 === 1 && board.centerSquareType === CenterSquareType.FREE;
  const baseline = hasFreeCenterAutoComplete ? 1 : 0;
  return board.completedTasks <= baseline;
}
