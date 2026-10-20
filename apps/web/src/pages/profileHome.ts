import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  Timeframe,
  computeLongestStreak,
  computeStreak,
  selectLastIncrementEntry,
} from '@oybc/shared';
import type {
  Board,
  SharedCounterGroup,
  SharedCounterMemberTask,
  Task,
  TaskEvent,
  UserPreferences,
} from '@oybc/shared';

/**
 * profileHome.ts — pure helpers behind the new Profile home
 * (`pages/ProfilePage.tsx`, Profile reorg PR2,
 * `design_handoff_profile_reorg/README.md` §Screens — Web `/profile` `#5a`).
 *
 * Kept framework-free and DB-free so every derivation (tile summaries, the
 * "logged X" relative label, counter recency ordering, most-recently-logged
 * member selection) is unit-testable without Dexie or React. The hook
 * (`hooks/useProfileHome.ts`) wires these to live queries; the page only
 * renders.
 */

// ─── Board settings tile ────────────────────────────────────────────────────

export interface BoardSettingsTileSummary {
  /** `"Defaults 3×3 · Free · Mon"`. */
  defaultsLine: string;
  /** `"2 repeating boards"` or `"No repeating boards yet"`. */
  repeatingLine: string;
}

function centerLabel(center: UserPreferences['defaultCenterType']): string {
  return center === CenterSquareType.FREE ? 'Free' : 'None';
}

function weekStartLabel(weekStartDay: UserPreferences['weekStartDay']): string {
  return weekStartDay === 'sunday' ? 'Sun' : 'Mon';
}

/**
 * Builds the Board settings tile's two summary lines (spec copy: `Defaults
 * 3×3 · Free · Mon` / `2 repeating boards` / `No repeating boards yet`).
 *
 * `repeatingBoardCount` is the FULL roster count (active + paused) — the
 * same set `BoardSettingsPage`'s "Repeating boards" list shows (its own
 * docstring: "EVERY spawn record (active AND paused) — this is the safety
 * net for paused boards"), so the tile's count always matches what tapping
 * through to the sub-page reveals.
 */
export function buildBoardSettingsTileSummary(
  prefs: Pick<UserPreferences, 'defaultBoardSize' | 'defaultCenterType' | 'weekStartDay'>,
  repeatingBoardCount: number,
): BoardSettingsTileSummary {
  const defaultsLine = `Defaults ${prefs.defaultBoardSize}×${prefs.defaultBoardSize} · ${centerLabel(
    prefs.defaultCenterType,
  )} · ${weekStartLabel(prefs.weekStartDay)}`;
  const repeatingLine =
    repeatingBoardCount > 0
      ? `${repeatingBoardCount} repeating board${repeatingBoardCount === 1 ? '' : 's'}`
      : 'No repeating boards yet';
  return { defaultsLine, repeatingLine };
}

// ─── Streak tile ─────────────────────────────────────────────────────────────

export interface StreakTileData {
  /** Daily BINGO streak — the tile's headline number (spec: "Number = Daily
   *  bingo streak", intentionally NOT the same metric as `StreaksPage`'s
   *  hero, which is the daily GREENLOG streak). */
  currentBingoStreak: number;
  /** Longest daily GREENLOG streak — reuses `StreaksPage`'s own "Longest"
   *  stat verbatim (spec: "'Longest' and 'Greenlogs' from the same stats
   *  used by StreaksView"). */
  longestGreenlogStreak: number;
  /** Total completed (GREENLOGed), non-deleted boards — same count
   *  `StreaksPage` shows in its stat trio. */
  greenlogCount: number;
  /** True when there's no active bingo streak — renders the dashed empty
   *  tile ("No streak yet"). */
  isEmpty: boolean;
}

export function buildStreakTileData(
  boards: Board[],
  weekStartDay: UserPreferences['weekStartDay'],
  now: Date,
): StreakTileData {
  const currentBingoStreak = computeStreak(
    Timeframe.DAILY,
    AchievementTrigger.BINGO,
    boards,
    weekStartDay,
    now,
  );
  const longestGreenlogStreak = computeLongestStreak(Timeframe.DAILY, boards, weekStartDay, now);
  const greenlogCount = boards.filter((b) => b.status === BoardStatus.COMPLETED && !b.isDeleted).length;
  return {
    currentBingoStreak,
    longestGreenlogStreak,
    greenlogCount,
    isEmpty: currentBingoStreak === 0,
  };
}

// ─── Shared counters block ──────────────────────────────────────────────────

/** One counter row ready for the Profile home's "Shared counters" card. */
export interface ProfileHomeCounterRow {
  group: SharedCounterGroup;
  /** ISO timestamp this counter was most recently logged at (the selected
   *  entry's `createdAt` — real wall-clock log time — falling back to the
   *  source task's `createdAt` when it has never been logged). */
  lastLoggedAt: string;
  /** The member (non-source task) most recently reached by that log, or
   *  `null` when the counter has no linked members yet. */
  member: SharedCounterMemberTask | null;
}

/**
 * Resolves the ISO timestamp a counter was most recently logged at.
 *
 * `selectLastIncrementEntry` (from `@oybc/shared`) already picks the most
 * recent non-deleted, non-seed increment event ordered by `createdAt` (the
 * moment the user pressed Log — not `occurredAt`, which a late log on a
 * closed board stamps into the past). No entry → fall back to the source
 * task's own `createdAt` (a brand-new counter that's never been logged),
 * per the owner note "fallback createdAt — NO new persisted field".
 */
export function lastLoggedTimestamp(
  group: SharedCounterGroup,
  tasksById: ReadonlyMap<string, Task>,
  eventsBySourceId: Readonly<Record<string, TaskEvent[]>>,
): string {
  const events = eventsBySourceId[group.counterId] ?? [];
  const entry = selectLastIncrementEntry(events, group.counterId);
  if (entry) return entry.createdAt;
  return tasksById.get(group.counterId)?.createdAt ?? '';
}

/**
 * How many shared counters Profile home lists before "All N ›" (owner,
 * 2026-10-12: raised from 2 — two rows left the page mostly empty).
 * iOS twin: `ProfileHomeViewModel.profileCounterRows`.
 */
export const PROFILE_COUNTER_ROWS = 5;

/**
 * Orders a user's shared-counter groups by most-recently-logged first and
 * returns the top `limit` ("All N ›" pushes the hub for the rest). Equal
 * timestamps break on `counterId` ascending — the same rule as iOS
 * `ProfileHomeViewModel.orderCountersByRecency`, so both platforms show the
 * same rows for the same data.
 */
export function selectRecentCounters(
  groups: readonly SharedCounterGroup[],
  tasksById: ReadonlyMap<string, Task>,
  eventsBySourceId: Readonly<Record<string, TaskEvent[]>>,
  limit = PROFILE_COUNTER_ROWS,
): ProfileHomeCounterRow[] {
  return groups
    .map((group) => ({
      group,
      lastLoggedAt: lastLoggedTimestamp(group, tasksById, eventsBySourceId),
      member: selectMostRecentlyLoggedMember(group),
    }))
    .sort((a, b) => {
      if (a.lastLoggedAt !== b.lastLoggedAt) return a.lastLoggedAt < b.lastLoggedAt ? 1 : -1;
      return a.group.counterId < b.group.counterId ? -1 : a.group.counterId > b.group.counterId ? 1 : 0;
    })
    .slice(0, limit);
}

/**
 * Picks the group's "most recently logged member" for the row's progress
 * column (spec: "member label + 6px progress bar for the most recently
 * logged member").
 *
 * Only the source task owns log events, and a log made now counts on every
 * placement whose board is in play (`isActive` — the Boards tab's rule), so
 * the card the latest log reached is an ACTIVE one. Active cards win; ties
 * (several boards in play) break on board name, then card id, for a
 * deterministic, stable pick. A linked row's own fields are never read —
 * since TASK_WINDOW_REWORK slice 5 a log writes the root alone.
 *
 * Returns `null` when the counter has no linked members yet (a hub-born,
 * member-less counter) — the row then shows no member column.
 */
export function selectMostRecentlyLoggedMember(
  group: SharedCounterGroup,
): SharedCounterMemberTask | null {
  let best: SharedCounterMemberTask | null = null;
  const rank = (m: SharedCounterMemberTask): [number, string, string] => [
    m.isActive ? 0 : 1,
    m.boardName ?? '',
    m.boardTaskId,
  ];
  for (const member of group.tasks) {
    if (member.isSource) continue;
    if (best === null) {
      best = member;
      continue;
    }
    const [a1, a2, a3] = rank(member);
    const [b1, b2, b3] = rank(best);
    if (a1 < b1 || (a1 === b1 && (a2 < b2 || (a2 === b2 && a3 < b3)))) best = member;
  }
  return best;
}

/**
 * Human "logged X" relative label (spec copy: `logged {today|yesterday|Mon…}`).
 * Compares LOCAL calendar days: today / yesterday / a short weekday name for
 * the rest of the last 7 days / a short month-day date beyond that. Mirrors
 * `StreaksPage`'s `relativeLabel` shape but adds the weekday-name rung the
 * counters row spec calls for.
 *
 * @returns `''` for an unparseable timestamp (defensive; never expected).
 */
export function formatLastLoggedLabel(iso: string, now: Date): string {
  const target = new Date(iso);
  if (Number.isNaN(target.getTime())) return '';

  const dayStart = (d: Date): Date => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const todayStart = dayStart(now);
  const targetStart = dayStart(target);
  const diffDays = Math.round((todayStart.getTime() - targetStart.getTime()) / 86_400_000);

  if (diffDays <= 0) return 'today';
  if (diffDays === 1) return 'yesterday';
  if (diffDays < 7) return targetStart.toLocaleDateString(undefined, { weekday: 'short' });
  return targetStart.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
