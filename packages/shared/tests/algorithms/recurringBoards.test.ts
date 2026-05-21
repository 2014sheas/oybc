import {
  PARENT_TIMEFRAMES,
  findPendingRecurringBoards,
  getCoreBoardSlots,
  getParentBoards,
} from '../../src/algorithms/recurringBoards';
import { getTimeframeBoundaries } from '../../src/algorithms/calendarBoundaries';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
} from '../../src/constants/enums';
import {
  DEFAULT_USER_PREFERENCES,
  type UserPreferences,
} from '../../src/types/user';
import type { Board } from '../../src/types/board';

// ─── Test fixtures ────────────────────────────────────────────────────────────

// Defaults are all-true post-6.1d, so PREFS_ALL_ENABLED is just the defaults
// (kept as a named constant for test readability). PREFS_NONE_ENABLED is an
// explicit override for the disabled-prefs test cases.
const PREFS_ALL_ENABLED: UserPreferences = { ...DEFAULT_USER_PREFERENCES };

const PREFS_NONE_ENABLED: UserPreferences = {
  ...DEFAULT_USER_PREFERENCES,
  recurringDailyEnabled: false,
  recurringWeeklyEnabled: false,
  recurringMonthlyEnabled: false,
  recurringYearlyEnabled: false,
};

/** Build a Board whose `startDate`/`endDate` match the boundary helper for the
 * given timeframe + reference date. Used to seed "this window already has a
 * board" cases. */
function boardForWindow(
  timeframe: Timeframe,
  referenceDate: Date,
  overrides: Partial<Board> = {}
): Board {
  const { startDate, endDate } = getTimeframeBoundaries(
    timeframe,
    referenceDate,
    'monday'
  );
  return {
    id: `board-${timeframe}-${startDate}`,
    userId: 'u1',
    name: `${timeframe} board`,
    status: BoardStatus.ACTIVE,
    boardSize: 5,
    timeframe,
    startDate,
    endDate,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 25,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: '2026-05-01T00:00:00.000',
    updatedAt: '2026-05-01T00:00:00.000',
    version: 1,
    isDeleted: false,
    // Default to non-core so each test must opt in to suppression
    // explicitly with `{ isCore: true }`. Surfaces the new semantic
    // in the test source instead of hiding it in the fixture.
    isCore: false,
    ...overrides,
  };
}

// ─── PARENT_TIMEFRAMES ────────────────────────────────────────────────────────

describe('PARENT_TIMEFRAMES', () => {
  it('encodes daily → [weekly, monthly, yearly]', () => {
    expect(PARENT_TIMEFRAMES[Timeframe.DAILY]).toEqual([
      Timeframe.WEEKLY,
      Timeframe.MONTHLY,
      Timeframe.YEARLY,
    ]);
  });

  it('encodes weekly → [monthly, yearly]', () => {
    expect(PARENT_TIMEFRAMES[Timeframe.WEEKLY]).toEqual([
      Timeframe.MONTHLY,
      Timeframe.YEARLY,
    ]);
  });

  it('encodes monthly → [yearly]', () => {
    expect(PARENT_TIMEFRAMES[Timeframe.MONTHLY]).toEqual([Timeframe.YEARLY]);
  });

  it('encodes yearly → [] (no parents)', () => {
    expect(PARENT_TIMEFRAMES[Timeframe.YEARLY]).toEqual([]);
  });

  it('encodes custom → [] (excluded from Phase 1)', () => {
    expect(PARENT_TIMEFRAMES[Timeframe.CUSTOM]).toEqual([]);
  });
});

// ─── findPendingRecurringBoards ───────────────────────────────────────────────

describe('findPendingRecurringBoards', () => {
  describe('disabled prefs', () => {
    it('returns empty when all four flags are false', () => {
      const result = findPendingRecurringBoards(
        [],
        PREFS_NONE_ENABLED,
        new Date(2026, 4, 1)
      );
      expect(result).toEqual([]);
    });

    it('skips disabled timeframes even when boards are absent', () => {
      // Only daily enabled
      const prefs: UserPreferences = {
        ...PREFS_NONE_ENABLED,
        recurringDailyEnabled: true,
      };
      const result = findPendingRecurringBoards(
        [],
        prefs,
        new Date(2026, 4, 1)
      );
      expect(result).toHaveLength(1);
      expect(result[0].timeframe).toBe(Timeframe.DAILY);
    });
  });

  describe('all enabled, no boards', () => {
    it('returns one entry per enabled timeframe', () => {
      const result = findPendingRecurringBoards(
        [],
        PREFS_ALL_ENABLED,
        new Date(2026, 4, 1)
      );
      expect(result.map((p) => p.timeframe)).toEqual([
        Timeframe.YEARLY,
        Timeframe.MONTHLY,
        Timeframe.WEEKLY,
        Timeframe.DAILY,
      ]);
    });

    it('orders longest-window first (yearly → monthly → weekly → daily)', () => {
      const result = findPendingRecurringBoards(
        [],
        PREFS_ALL_ENABLED,
        new Date(2026, 4, 1)
      );
      const order = result.map((p) => p.timeframe);
      expect(order.indexOf(Timeframe.YEARLY)).toBeLessThan(
        order.indexOf(Timeframe.MONTHLY)
      );
      expect(order.indexOf(Timeframe.MONTHLY)).toBeLessThan(
        order.indexOf(Timeframe.WEEKLY)
      );
      expect(order.indexOf(Timeframe.WEEKLY)).toBeLessThan(
        order.indexOf(Timeframe.DAILY)
      );
    });

    it('attaches deterministic startDate/endDate from getTimeframeBoundaries', () => {
      const now = new Date(2026, 4, 1, 14, 30); // May 1 2:30 PM
      const result = findPendingRecurringBoards(
        [],
        PREFS_ALL_ENABLED,
        now
      );
      const daily = result.find((p) => p.timeframe === Timeframe.DAILY)!;
      const expected = getTimeframeBoundaries(Timeframe.DAILY, now, 'monday');
      expect(daily.startDate).toBe(expected.startDate);
      expect(daily.endDate).toBe(expected.endDate);
    });

    it('attaches a non-empty suggestedName per entry', () => {
      const result = findPendingRecurringBoards(
        [],
        PREFS_ALL_ENABLED,
        new Date(2026, 4, 1)
      );
      for (const entry of result) {
        expect(entry.suggestedName).toBeTruthy();
        expect(entry.suggestedName.length).toBeGreaterThan(0);
      }
    });
  });

  describe('window-already-covered suppression', () => {
    it('suppresses daily when a core daily board exists for today', () => {
      const now = new Date(2026, 4, 1);
      const todaysDaily = boardForWindow(Timeframe.DAILY, now, { isCore: true });
      const result = findPendingRecurringBoards(
        [todaysDaily],
        PREFS_ALL_ENABLED,
        now
      );
      const timeframes = result.map((p) => p.timeframe);
      expect(timeframes).not.toContain(Timeframe.DAILY);
      expect(timeframes).toContain(Timeframe.WEEKLY);
    });

    it('does NOT suppress when only a non-core daily exists for today', () => {
      // Regression: an ad-hoc weekly/daily board (e.g. user clicks
      // Create directly without going through the banner) used to
      // silently dismiss the suggestion. Now it must not.
      const now = new Date(2026, 4, 1);
      const adhoc = boardForWindow(Timeframe.DAILY, now); // isCore: false default
      const result = findPendingRecurringBoards(
        [adhoc],
        PREFS_ALL_ENABLED,
        now
      );
      expect(result.map((p) => p.timeframe)).toContain(Timeframe.DAILY);
    });

    it('suppresses daily when a core daily exists even if a non-core daily also exists', () => {
      const now = new Date(2026, 4, 1);
      const adhoc = boardForWindow(Timeframe.DAILY, now, { id: 'adhoc' });
      const core = boardForWindow(Timeframe.DAILY, now, { id: 'core', isCore: true });
      const result = findPendingRecurringBoards(
        [adhoc, core],
        PREFS_ALL_ENABLED,
        now
      );
      expect(result.map((p) => p.timeframe)).not.toContain(Timeframe.DAILY);
    });

    it('does NOT suppress daily when only YESTERDAY has a board', () => {
      const yesterday = new Date(2026, 4, 1);
      const today = new Date(2026, 4, 2);
      const yesterdaysDaily = boardForWindow(Timeframe.DAILY, yesterday);
      const result = findPendingRecurringBoards(
        [yesterdaysDaily],
        PREFS_ALL_ENABLED,
        today
      );
      expect(result.map((p) => p.timeframe)).toContain(Timeframe.DAILY);
    });

    it('treats soft-deleted boards as not present', () => {
      const now = new Date(2026, 4, 1);
      const deletedDaily = boardForWindow(Timeframe.DAILY, now, {
        isDeleted: true,
        deletedAt: '2026-05-01T08:00:00.000',
      });
      const result = findPendingRecurringBoards(
        [deletedDaily],
        PREFS_ALL_ENABLED,
        now
      );
      expect(result.map((p) => p.timeframe)).toContain(Timeframe.DAILY);
    });

    it('matches even if multiple core boards exist for the same window', () => {
      const now = new Date(2026, 4, 1);
      const a = boardForWindow(Timeframe.DAILY, now, { id: 'daily-a', isCore: true });
      const b = boardForWindow(Timeframe.DAILY, now, { id: 'daily-b', isCore: true });
      const result = findPendingRecurringBoards(
        [a, b],
        PREFS_ALL_ENABLED,
        now
      );
      expect(result.map((p) => p.timeframe)).not.toContain(Timeframe.DAILY);
    });

    it('does not match a daily for today if only a core weekly exists', () => {
      const now = new Date(2026, 4, 1);
      const weekly = boardForWindow(Timeframe.WEEKLY, now, { isCore: true });
      const result = findPendingRecurringBoards(
        [weekly],
        PREFS_ALL_ENABLED,
        now
      );
      expect(result.map((p) => p.timeframe)).toContain(Timeframe.DAILY);
      expect(result.map((p) => p.timeframe)).not.toContain(Timeframe.WEEKLY);
    });
  });

  describe('week-start variation', () => {
    it('matches a core weekly board recorded with the same week-start preference', () => {
      const wednesdayMar25 = new Date(2026, 2, 25);
      const mondayPrefs: UserPreferences = {
        ...PREFS_ALL_ENABLED,
        weekStartDay: 'monday',
      };
      const weekly = boardForWindow(Timeframe.WEEKLY, wednesdayMar25, { isCore: true });
      const result = findPendingRecurringBoards(
        [weekly],
        mondayPrefs,
        wednesdayMar25
      );
      expect(result.map((p) => p.timeframe)).not.toContain(Timeframe.WEEKLY);
    });

    it('does NOT match a Monday-week board when the user has Sunday-week prefs', () => {
      const wednesdayMar25 = new Date(2026, 2, 25);
      const mondayBoundaries = getTimeframeBoundaries(
        Timeframe.WEEKLY,
        wednesdayMar25,
        'monday'
      );
      const sundayBoundaries = getTimeframeBoundaries(
        Timeframe.WEEKLY,
        wednesdayMar25,
        'sunday'
      );
      // Monday and Sunday weeks have different startDate strings on the same Wednesday
      expect(mondayBoundaries.startDate).not.toBe(sundayBoundaries.startDate);

      const mondayBoard = boardForWindow(Timeframe.WEEKLY, wednesdayMar25);
      const sundayPrefs: UserPreferences = {
        ...PREFS_ALL_ENABLED,
        weekStartDay: 'sunday',
      };
      const result = findPendingRecurringBoards(
        [mondayBoard],
        sundayPrefs,
        wednesdayMar25
      );
      // Sunday-week pref → recomputes the current weekly window with Sunday
      // start → no match against a Monday-week board → weekly is pending again
      expect(result.map((p) => p.timeframe)).toContain(Timeframe.WEEKLY);
    });
  });

  describe('year-boundary multi-window rollover (Jan 1 case)', () => {
    it('returns all four timeframes pending when Jan 1 has no boards', () => {
      const jan1 = new Date(2026, 0, 1);
      const result = findPendingRecurringBoards(
        [],
        PREFS_ALL_ENABLED,
        jan1
      );
      expect(result.map((p) => p.timeframe)).toEqual([
        Timeframe.YEARLY,
        Timeframe.MONTHLY,
        Timeframe.WEEKLY,
        Timeframe.DAILY,
      ]);
    });

    it('still pends new-year boards even when last-year boards exist', () => {
      const dec31 = new Date(2025, 11, 31);
      const jan1 = new Date(2026, 0, 1);
      const lastYearsBoards = [
        boardForWindow(Timeframe.YEARLY, dec31),
        boardForWindow(Timeframe.MONTHLY, dec31),
        boardForWindow(Timeframe.DAILY, dec31),
      ];
      const result = findPendingRecurringBoards(
        lastYearsBoards,
        PREFS_ALL_ENABLED,
        jan1
      );
      expect(result.map((p) => p.timeframe)).toContain(Timeframe.YEARLY);
      expect(result.map((p) => p.timeframe)).toContain(Timeframe.MONTHLY);
      expect(result.map((p) => p.timeframe)).toContain(Timeframe.DAILY);
    });
  });
});

// ─── getParentBoards ──────────────────────────────────────────────────────────

describe('getParentBoards', () => {
  const may1 = new Date(2026, 4, 1);

  it('returns empty for yearly (no parents)', () => {
    const yearly = boardForWindow(Timeframe.YEARLY, may1);
    expect(getParentBoards(Timeframe.YEARLY, [yearly], may1)).toEqual([]);
  });

  it('returns empty for custom (excluded from Phase 1)', () => {
    expect(getParentBoards(Timeframe.CUSTOM, [], may1)).toEqual([]);
  });

  it('returns currently-active weekly + monthly + yearly for daily', () => {
    const weekly = boardForWindow(Timeframe.WEEKLY, may1, { id: 'weekly' });
    const monthly = boardForWindow(Timeframe.MONTHLY, may1, { id: 'monthly' });
    const yearly = boardForWindow(Timeframe.YEARLY, may1, { id: 'yearly' });
    const result = getParentBoards(
      Timeframe.DAILY,
      [weekly, monthly, yearly],
      may1
    );
    const ids = result.map((b) => b.id).sort();
    expect(ids).toEqual(['monthly', 'weekly', 'yearly']);
  });

  it('returns only monthly + yearly for weekly (excludes other weeklies)', () => {
    const weekly = boardForWindow(Timeframe.WEEKLY, may1, { id: 'weekly' });
    const monthly = boardForWindow(Timeframe.MONTHLY, may1, { id: 'monthly' });
    const yearly = boardForWindow(Timeframe.YEARLY, may1, { id: 'yearly' });
    const result = getParentBoards(
      Timeframe.WEEKLY,
      [weekly, monthly, yearly],
      may1
    );
    const ids = result.map((b) => b.id).sort();
    expect(ids).toEqual(['monthly', 'yearly']);
  });

  it('excludes deleted parents', () => {
    const monthly = boardForWindow(Timeframe.MONTHLY, may1, {
      isDeleted: true,
    });
    expect(getParentBoards(Timeframe.DAILY, [monthly], may1)).toEqual([]);
  });

  it('excludes non-active parents (DRAFT / COMPLETED / ARCHIVED)', () => {
    const draft = boardForWindow(Timeframe.MONTHLY, may1, {
      id: 'draft',
      status: BoardStatus.DRAFT,
    });
    const completed = boardForWindow(Timeframe.MONTHLY, may1, {
      id: 'completed',
      status: BoardStatus.COMPLETED,
    });
    const archived = boardForWindow(Timeframe.MONTHLY, may1, {
      id: 'archived',
      status: BoardStatus.ARCHIVED,
    });
    expect(
      getParentBoards(Timeframe.DAILY, [draft, completed, archived], may1)
    ).toEqual([]);
  });

  it('excludes parents whose window has expired (last month)', () => {
    const lastMonth = new Date(2026, 3, 1); // April 1
    const today = new Date(2026, 4, 15); // May 15
    const lastMonthsMonthly = boardForWindow(Timeframe.MONTHLY, lastMonth);
    expect(
      getParentBoards(Timeframe.DAILY, [lastMonthsMonthly], today)
    ).toEqual([]);
  });

  it('returns the empty list (not undefined) when no parents match', () => {
    const result = getParentBoards(Timeframe.DAILY, [], may1);
    expect(result).toEqual([]);
    expect(Array.isArray(result)).toBe(true);
  });

  it('does not return sibling-timeframe boards (e.g., another daily)', () => {
    const sibling = boardForWindow(Timeframe.DAILY, may1, { id: 'sibling' });
    expect(getParentBoards(Timeframe.DAILY, [sibling], may1)).toEqual([]);
  });
});

// ─── getCoreBoardSlots ────────────────────────────────────────────────────────

describe('getCoreBoardSlots', () => {
  const NOW = new Date(2026, 4, 18, 12, 0, 0); // Mon May 18, 2026 noon

  it('returns one slot per enabled timeframe, daily-first', () => {
    const slots = getCoreBoardSlots([], PREFS_ALL_ENABLED, NOW);
    expect(slots).toHaveLength(4);
    expect(slots.map((s) => s.timeframe)).toEqual([
      Timeframe.DAILY,
      Timeframe.WEEKLY,
      Timeframe.MONTHLY,
      Timeframe.YEARLY,
    ]);
  });

  it('returns empty array when no recurring timeframes are enabled', () => {
    expect(getCoreBoardSlots([], PREFS_NONE_ENABLED, NOW)).toEqual([]);
  });

  it('respects per-timeframe disable — only enabled timeframes appear', () => {
    const dailyOnly: UserPreferences = {
      ...DEFAULT_USER_PREFERENCES,
      recurringDailyEnabled: true,
      recurringWeeklyEnabled: false,
      recurringMonthlyEnabled: false,
      recurringYearlyEnabled: false,
    };
    const slots = getCoreBoardSlots([], dailyOnly, NOW);
    expect(slots).toHaveLength(1);
    expect(slots[0].timeframe).toBe(Timeframe.DAILY);
  });

  it('populates currentBoard when an isCore board matches the window', () => {
    const todayCore = boardForWindow(Timeframe.DAILY, NOW, {
      id: 'core-daily',
      isCore: true,
    });
    const slots = getCoreBoardSlots([todayCore], PREFS_ALL_ENABLED, NOW);
    const daily = slots.find((s) => s.timeframe === Timeframe.DAILY);
    expect(daily?.currentBoard?.id).toBe('core-daily');
    // The other 3 enabled timeframes still appear but unfilled.
    expect(slots.filter((s) => s.currentBoard === null)).toHaveLength(3);
  });

  it('ignores non-core boards even when the window matches', () => {
    // A user manually created today's daily without the banner — that's
    // a non-core board. It must NOT satisfy the daily slot.
    const todayManual = boardForWindow(Timeframe.DAILY, NOW, {
      id: 'manual-daily',
      isCore: false,
    });
    const slots = getCoreBoardSlots([todayManual], PREFS_ALL_ENABLED, NOW);
    const daily = slots.find((s) => s.timeframe === Timeframe.DAILY);
    expect(daily?.currentBoard).toBeNull();
  });

  it('ignores soft-deleted core boards', () => {
    const deletedCore = boardForWindow(Timeframe.DAILY, NOW, {
      id: 'deleted-daily',
      isCore: true,
      isDeleted: true,
    });
    const slots = getCoreBoardSlots([deletedCore], PREFS_ALL_ENABLED, NOW);
    const daily = slots.find((s) => s.timeframe === Timeframe.DAILY);
    expect(daily?.currentBoard).toBeNull();
  });

  it('does not match a core board from a previous window', () => {
    const lastWeek = new Date(2026, 4, 11, 12, 0, 0); // Mon May 11
    const lastWeeksCore = boardForWindow(Timeframe.WEEKLY, lastWeek, {
      id: 'last-week-core',
      isCore: true,
    });
    const slots = getCoreBoardSlots([lastWeeksCore], PREFS_ALL_ENABLED, NOW);
    const weekly = slots.find((s) => s.timeframe === Timeframe.WEEKLY);
    expect(weekly?.currentBoard).toBeNull();
  });

  it('windowLabel matches formatTimeframeLabel for the current window', () => {
    const slots = getCoreBoardSlots([], PREFS_ALL_ENABLED, NOW);
    const monthly = slots.find((s) => s.timeframe === Timeframe.MONTHLY);
    expect(monthly?.windowLabel).toBe('May 2026');
    const yearly = slots.find((s) => s.timeframe === Timeframe.YEARLY);
    expect(yearly?.windowLabel).toBe('2026');
  });
});
