import { computeStreak, computeAllStreaks } from '../../src/algorithms/streaks';
import {
  getTimeframeBoundaries,
  stepWindow,
} from '../../src/algorithms/calendarBoundaries';
import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  Timeframe,
} from '../../src/constants/enums';
import type { Board } from '../../src/types/board';

// ─── Fixtures ───────────────────────────────────────────────────────────────

// Mon Jun 15 2026, midday — a Monday, so weekly (monday-start) windows align.
const NOW = new Date(2026, 5, 15, 12, 0, 0);

type BoardOpts = {
  linesCompleted?: number;
  status?: BoardStatus;
  isCore?: boolean;
  isDeleted?: boolean;
};

function coreBoard(
  timeframe: Timeframe,
  window: { startDate: string; endDate: string },
  opts: BoardOpts = {},
): Board {
  return {
    id: `b-${timeframe}-${window.startDate}`,
    userId: 'u1',
    name: 'core',
    status: opts.status ?? BoardStatus.ACTIVE,
    boardSize: 5,
    timeframe,
    startDate: window.startDate,
    endDate: window.endDate,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 25,
    completedTasks: 0,
    linesCompleted: opts.linesCompleted ?? 0,
    createdAt: '2026-01-01T00:00:00.000',
    updatedAt: '2026-01-01T00:00:00.000',
    version: 1,
    isDeleted: opts.isDeleted ?? false,
    isCore: opts.isCore ?? true,
  };
}

/** Windows [current, prev, prev-1, …] going back `count` steps. */
function windowsBack(timeframe: Timeframe, now: Date, count: number) {
  const out = [getTimeframeBoundaries(timeframe, now, 'monday')];
  for (let i = 1; i < count; i++) {
    out.push(stepWindow(timeframe, out[i - 1].startDate, -1, 'monday'));
  }
  return out;
}

const greenlog: BoardOpts = { status: BoardStatus.COMPLETED, linesCompleted: 8 };
const bingoOnly: BoardOpts = { status: BoardStatus.ACTIVE, linesCompleted: 2 };

const streak = (tf: Timeframe, c: AchievementTrigger, boards: Board[]) =>
  computeStreak(tf, c, boards, 'monday', NOW);

// ─── computeStreak ──────────────────────────────────────────────────────────

describe('computeStreak', () => {
  it('returns 0 when there are no core boards', () => {
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, [])).toBe(0);
    expect(streak(Timeframe.DAILY, AchievementTrigger.BINGO, [])).toBe(0);
  });

  it('returns 0 for CUSTOM (no recurrence cadence)', () => {
    const w = getTimeframeBoundaries(Timeframe.DAILY, NOW, 'monday');
    const boards = [coreBoard(Timeframe.DAILY, w, greenlog)];
    expect(streak(Timeframe.CUSTOM, AchievementTrigger.GREENLOG, boards)).toBe(0);
  });

  it('returns 0 for INDEFINITE (no recurrence cadence)', () => {
    const w = getTimeframeBoundaries(Timeframe.DAILY, NOW, 'monday');
    const boards = [coreBoard(Timeframe.DAILY, w, greenlog)];
    expect(streak(Timeframe.INDEFINITE, AchievementTrigger.GREENLOG, boards)).toBe(0);
    expect(streak(Timeframe.INDEFINITE, AchievementTrigger.BINGO, boards)).toBe(0);
  });

  it('counts consecutive achieved windows up to the first miss', () => {
    const w = windowsBack(Timeframe.DAILY, NOW, 5);
    // w0,w1,w2 greenlogged; w3 has no board → breaks.
    const boards = [
      coreBoard(Timeframe.DAILY, w[0], greenlog),
      coreBoard(Timeframe.DAILY, w[1], greenlog),
      coreBoard(Timeframe.DAILY, w[2], greenlog),
    ];
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, boards)).toBe(3);
  });

  it('gives the current window grace when it is not yet achieved', () => {
    const w = windowsBack(Timeframe.DAILY, NOW, 5);
    // current (w0) exists but only active (not greenlogged); w1,w2 greenlogged.
    const boards = [
      coreBoard(Timeframe.DAILY, w[0], { status: BoardStatus.ACTIVE }),
      coreBoard(Timeframe.DAILY, w[1], greenlog),
      coreBoard(Timeframe.DAILY, w[2], greenlog),
    ];
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, boards)).toBe(2);
  });

  it('gives grace even when the current window has no board at all', () => {
    const w = windowsBack(Timeframe.DAILY, NOW, 5);
    // no w0 board; w1,w2 greenlogged.
    const boards = [
      coreBoard(Timeframe.DAILY, w[1], greenlog),
      coreBoard(Timeframe.DAILY, w[2], greenlog),
    ];
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, boards)).toBe(2);
  });

  it('breaks on a closed window with a missing board', () => {
    const w = windowsBack(Timeframe.DAILY, NOW, 5);
    // w0 greenlog, w1 MISSING, w2 greenlog → only w0 counts.
    const boards = [
      coreBoard(Timeframe.DAILY, w[0], greenlog),
      coreBoard(Timeframe.DAILY, w[2], greenlog),
    ];
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, boards)).toBe(1);
  });

  it('distinguishes bingo from greenlog criteria', () => {
    const w = windowsBack(Timeframe.DAILY, NOW, 4);
    // w0,w1 have a bingo line but are NOT greenlogged; w2 missing.
    const boards = [
      coreBoard(Timeframe.DAILY, w[0], bingoOnly),
      coreBoard(Timeframe.DAILY, w[1], bingoOnly),
    ];
    expect(streak(Timeframe.DAILY, AchievementTrigger.BINGO, boards)).toBe(2);
    // greenlog: w0 grace (not greenlogged), w1 closed+not-greenlogged → break → 0.
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, boards)).toBe(0);
  });

  it('ignores non-core boards', () => {
    const w = windowsBack(Timeframe.DAILY, NOW, 3);
    const boards = [
      coreBoard(Timeframe.DAILY, w[0], { ...greenlog, isCore: false }),
      coreBoard(Timeframe.DAILY, w[1], { ...greenlog, isCore: false }),
    ];
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, boards)).toBe(0);
  });

  it('ignores soft-deleted boards', () => {
    const w = windowsBack(Timeframe.DAILY, NOW, 3);
    const boards = [
      coreBoard(Timeframe.DAILY, w[0], { ...greenlog, isDeleted: true }),
    ];
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, boards)).toBe(0);
  });

  it('reflects reversibility — un-completing the latest board drops the streak', () => {
    const w = windowsBack(Timeframe.DAILY, NOW, 4);
    // w0 reverted to active, w1 greenlog, w2 greenlog → grace on w0, count 2.
    const reverted = [
      coreBoard(Timeframe.DAILY, w[0], { status: BoardStatus.ACTIVE }),
      coreBoard(Timeframe.DAILY, w[1], greenlog),
      coreBoard(Timeframe.DAILY, w[2], greenlog),
    ];
    expect(streak(Timeframe.DAILY, AchievementTrigger.GREENLOG, reverted)).toBe(2);
  });

  it('computes weekly streaks using weekStartDay windows', () => {
    const w = windowsBack(Timeframe.WEEKLY, NOW, 4);
    const boards = [
      coreBoard(Timeframe.WEEKLY, w[0], greenlog),
      coreBoard(Timeframe.WEEKLY, w[1], greenlog),
    ];
    expect(streak(Timeframe.WEEKLY, AchievementTrigger.GREENLOG, boards)).toBe(2);
  });
});

// ─── computeAllStreaks ──────────────────────────────────────────────────────

describe('computeAllStreaks', () => {
  it('returns all four timeframes with bingo + greenlog', () => {
    const dw = getTimeframeBoundaries(Timeframe.DAILY, NOW, 'monday');
    const boards = [coreBoard(Timeframe.DAILY, dw, greenlog)];
    const all = computeAllStreaks(boards, 'monday', NOW);

    expect(all[Timeframe.DAILY]).toEqual({ bingo: 1, greenlog: 1 });
    expect(all[Timeframe.WEEKLY]).toEqual({ bingo: 0, greenlog: 0 });
    expect(all[Timeframe.MONTHLY]).toEqual({ bingo: 0, greenlog: 0 });
    expect(all[Timeframe.YEARLY]).toEqual({ bingo: 0, greenlog: 0 });
  });
});
