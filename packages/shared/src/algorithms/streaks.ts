/**
 * Streaks — consecutive recurring core-board windows the user "achieved".
 *
 * Two independent streak kinds per timeframe, keyed off the same thresholds as
 * Achievement watcher tasks:
 *   - BINGO    → the window's core board has `linesCompleted >= 1`.
 *   - GREENLOG → the window's core board is `status === COMPLETED` (full board).
 *
 * Streaks apply to **core boards only** (`isCore === true`) — ad-hoc / custom
 * boards have no recurrence cadence. Computed live from board state (no separate
 * persisted log), so it stays offline-first and auto-consistent across devices;
 * the trade-off is that un-completing a task on an old board can retroactively
 * shift its streak.
 *
 * Rules:
 *   - Walk windows backward from the one containing `now`.
 *   - The CURRENT (in-progress) window gets grace: not achieving it yet never
 *     breaks the streak.
 *   - Any CLOSED window that has no core board, or whose core board didn't meet
 *     the criterion, ends the streak.
 *
 * No persistence, no platform code, no side effects — recompute on each call
 * (reactivity comes from the platform-side useLiveQuery / observed-store
 * wrappers). Mirrored by `apps/ios/OYBC/Services/Streaks.swift`.
 */

import { getTimeframeBoundaries, stepWindow } from './calendarBoundaries';
import type { WeekStartDay } from './calendarBoundaries';
import { AchievementTrigger, BoardStatus, Timeframe } from '../constants/enums';
import type { Board } from '../types/board';

/** The four recurring timeframes streaks apply to (CUSTOM has no cadence). */
export const STREAK_TIMEFRAMES = [
  Timeframe.DAILY,
  Timeframe.WEEKLY,
  Timeframe.MONTHLY,
  Timeframe.YEARLY,
] as const;

/** Safety backstop on how many windows we walk back. Real streaks are bounded
 * by the user's board history (the first window with no core board breaks the
 * loop); this only guards a pathological all-achieved history. */
const MAX_WINDOWS = 1000;

/** A timeframe's two streak counts. */
export interface StreakPair {
  bingo: number;
  greenlog: number;
}

/** Per-timeframe streaks for the four recurring timeframes. */
export type StreaksByTimeframe = {
  [Timeframe.DAILY]: StreakPair;
  [Timeframe.WEEKLY]: StreakPair;
  [Timeframe.MONTHLY]: StreakPair;
  [Timeframe.YEARLY]: StreakPair;
};

/** Whether a core board satisfies the streak criterion. Mirrors the Achievement
 * trigger semantics (BINGO = `linesCompleted >= 1`, GREENLOG = full board). */
function boardMeets(board: Board, criterion: AchievementTrigger): boolean {
  return criterion === AchievementTrigger.BINGO
    ? board.linesCompleted >= 1
    : board.status === BoardStatus.COMPLETED;
}

/**
 * Current streak (count of consecutive achieved windows) for one timeframe +
 * criterion. Returns 0 for `CUSTOM` or when no core boards exist.
 *
 * @param timeframe    DAILY / WEEKLY / MONTHLY / YEARLY (CUSTOM → 0).
 * @param criterion    BINGO or GREENLOG.
 * @param boards       All boards for the active user (caller scopes by userId).
 * @param weekStartDay First day of week — only affects WEEKLY windows.
 * @param now          Reference instant (frozen in tests).
 */
export function computeStreak(
  timeframe: Timeframe,
  criterion: AchievementTrigger,
  boards: Board[],
  weekStartDay: WeekStartDay,
  now: Date,
): number {
  // CUSTOM and INDEFINITE have no window cadence to walk → no streak.
  if (timeframe === Timeframe.CUSTOM || timeframe === Timeframe.INDEFINITE) return 0;

  // startDate → the core board for that window. Core boards write `startDate`
  // via `toLocalISO(window.start)`, the exact string `getTimeframeBoundaries`
  // returns, so window→board matching is a string-key lookup.
  const byStart = new Map<string, Board>();
  for (const b of boards) {
    if (b.isCore === true && !b.isDeleted && b.timeframe === timeframe) {
      byStart.set(b.startDate, b);
    }
  }
  if (byStart.size === 0) return 0;

  let streak = 0;
  let startDate = getTimeframeBoundaries(timeframe, now, weekStartDay).startDate;
  let isCurrent = true;

  for (let i = 0; i < MAX_WINDOWS; i++) {
    const board = byStart.get(startDate);
    const achieved = board !== undefined && boardMeets(board, criterion);

    if (achieved) {
      streak += 1;
    } else if (!isCurrent) {
      // A closed window with no achieving core board ends the streak.
      break;
    }
    // (current window not achieved → grace: don't break, keep walking back.)

    startDate = stepWindow(timeframe, startDate, -1, weekStartDay).startDate;
    isCurrent = false;
  }

  return streak;
}

/**
 * Compact, timeframe-aware streak label: "3d" / "2w" / "5mo" / "1y".
 * Shared by every streak surface (the window bar chip, the Profile streaks
 * page, the core-timeframe grid badge, the celebration overlay). Mirrors
 * `compactStreakLabel` in `apps/ios/OYBC/Services/Streaks.swift`.
 *
 * @param count     The streak count to format.
 * @param timeframe Controls the unit suffix appended to the count.
 */
export function compactStreakLabel(count: number, timeframe: Timeframe): string {
  const unit =
    timeframe === Timeframe.DAILY ? 'd' :
    timeframe === Timeframe.WEEKLY ? 'w' :
    timeframe === Timeframe.MONTHLY ? 'mo' :
    timeframe === Timeframe.YEARLY ? 'y' : '';
  return `${count}${unit}`;
}

/**
 * Longest historical greenlog streak for a single timeframe.
 *
 * Walks backward from the current window, counting consecutive windows whose
 * core board was GREENLOGed (`status === COMPLETED`). Stops when it has
 * processed the oldest known core-board window; it keeps walking through gaps
 * to find an earlier (possibly longer) run, retaining the max seen.
 *
 * **No grace for the current window** (unlike `computeStreak`): an unfinished
 * current window breaks the run. This reflects the design intent — "longest"
 * is actual past achievement, not projected.
 *
 * Mirrors `computeLongestStreak` in `apps/ios/OYBC/Services/Streaks.swift`.
 *
 * @param timeframe    DAILY / WEEKLY / MONTHLY / YEARLY (CUSTOM → 0).
 * @param boards       All boards for the active user (caller scopes by userId).
 * @param weekStartDay First day of week — only affects WEEKLY windows.
 * @param now          Reference instant (frozen in tests).
 */
export function computeLongestStreak(
  timeframe: Timeframe,
  boards: Board[],
  weekStartDay: WeekStartDay,
  now: Date,
): number {
  if (timeframe === Timeframe.CUSTOM || timeframe === Timeframe.INDEFINITE) return 0;

  const byStart = new Map<string, Board>();
  for (const b of boards) {
    if (b.isCore === true && !b.isDeleted && b.timeframe === timeframe) {
      byStart.set(b.startDate, b);
    }
  }
  if (byStart.size === 0) return 0;

  // Oldest window that could possibly be achieved — nothing predates the
  // user's first core board of this timeframe. Keys are local ISO strings
  // (zero-padded), so lexical order == chronological order.
  const oldestStart = [...byStart.keys()].sort()[0];

  let longest = 0;
  let currentRun = 0;
  let startDate = getTimeframeBoundaries(timeframe, now, weekStartDay).startDate;

  for (let i = 0; i < MAX_WINDOWS; i++) {
    const board = byStart.get(startDate);
    const achieved = board !== undefined && board.status === BoardStatus.COMPLETED;

    if (achieved) {
      currentRun += 1;
      if (currentRun > longest) longest = currentRun;
    } else {
      // A gap resets the current run — but we keep walking back to find an
      // earlier (possibly longer) run. `longest` retains the max seen.
      currentRun = 0;
    }

    // Stop once we've processed the oldest board's window; older windows
    // can only be gaps and won't extend the longest run.
    if (startDate <= oldestStart) break;

    startDate = stepWindow(timeframe, startDate, -1, weekStartDay).startDate;
  }

  return longest;
}

/**
 * Both streak kinds for all four recurring timeframes in one pass.
 */
export function computeAllStreaks(
  boards: Board[],
  weekStartDay: WeekStartDay,
  now: Date,
): StreaksByTimeframe {
  const pair = (tf: Timeframe): StreakPair => ({
    bingo: computeStreak(tf, AchievementTrigger.BINGO, boards, weekStartDay, now),
    greenlog: computeStreak(tf, AchievementTrigger.GREENLOG, boards, weekStartDay, now),
  });
  return {
    [Timeframe.DAILY]: pair(Timeframe.DAILY),
    [Timeframe.WEEKLY]: pair(Timeframe.WEEKLY),
    [Timeframe.MONTHLY]: pair(Timeframe.MONTHLY),
    [Timeframe.YEARLY]: pair(Timeframe.YEARLY),
  };
}
