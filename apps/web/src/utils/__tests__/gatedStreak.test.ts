import { describe, expect, it } from 'vitest';
import {
  AchievementTrigger,
  BoardStatus,
  CenterSquareType,
  Timeframe,
  type Board,
  type WeekStartDay,
} from '@oybc/shared';
import { gatedStreak } from '../gatedStreak';
import { getExpiryLabel, isBoardExpiringSoon } from '../boardDisplayUtils';

const MONDAY: WeekStartDay = 'monday';

/**
 * Late-mutation audit, findings 4 + 6 — values that used to change with
 * no user action (a render-time clock) or start wrong and correct
 * themselves (unready prefs/boards).
 */
describe('gatedStreak', () => {
  it('returns 0 while inputs are unready — never a number it would revise', () => {
    expect(gatedStreak(false, Timeframe.DAILY, AchievementTrigger.GREENLOG, [], MONDAY, new Date()))
      .toBe(0);
  });

  it('delegates to computeStreak once ready — and the SAME inputs give 0 while unready', () => {
    // Review-caught: the previous version asserted 0 with no boards, which
    // passes even if `gatedStreak` always returned 0 (i.e. if the gating
    // broke the feature). A real streak fixture distinguishes the branches.
    const now = new Date('2026-09-16T12:00:00');
    const greenlogged = (startISO: string, endISO: string): Board =>
      ({
        id: `b-${startISO}`, userId: 'u1', name: 'Daily', status: BoardStatus.COMPLETED,
        boardSize: 3, timeframe: Timeframe.DAILY, startDate: startISO, endDate: endISO,
        centerSquareType: CenterSquareType.NONE, isRandomized: false, isCore: true,
        totalTasks: 9, completedTasks: 9, linesCompleted: 8, completedLineIds: [],
        createdAt: startISO, updatedAt: startISO, version: 1, isDeleted: false,
      }) as Board;
    const boards = [
      greenlogged('2026-09-16T00:00:00.000', '2026-09-16T23:59:59.999'),
      greenlogged('2026-09-15T00:00:00.000', '2026-09-15T23:59:59.999'),
    ];

    const ready = gatedStreak(true, Timeframe.DAILY, AchievementTrigger.GREENLOG, boards, MONDAY, now);
    const unready = gatedStreak(false, Timeframe.DAILY, AchievementTrigger.GREENLOG, boards, MONDAY, now);

    expect(ready).toBeGreaterThan(0);   // the real value survives the gate
    expect(unready).toBe(0);            // ...and is withheld until ready
  });
});

describe('expiry helpers take a pinned `now` (shape C)', () => {
  const board = {
    status: 'active',
    timeframe: Timeframe.WEEKLY,
    endDate: '2026-09-20T23:59:59.999',
  };

  it('the SAME board reads differently at different instants — so callers must pin one', () => {
    const dayBefore = new Date('2026-09-20T10:00:00');
    const dayAfter = new Date('2026-09-21T10:00:00');
    expect(isBoardExpiringSoon(board, dayBefore)).toBe(true);
    expect(isBoardExpiringSoon(board, dayAfter)).toBe(false);
    expect(getExpiryLabel(board, dayAfter)).toBe('Expired');
  });

  it('the passed instant OVERRIDES the clock — the parameter is really used', () => {
    // Review-caught: comparing a call to itself passes even if the
    // function ignores `now` and reads the clock internally. Pinning a
    // FAR-PAST instant proves the parameter drives the answer: a board
    // ending in 2026 is not expiring-soon when "now" is 2020.
    const longBefore = new Date('2020-01-01T00:00:00');
    expect(isBoardExpiringSoon(board, longBefore)).toBe(false);
    expect(getExpiryLabel(board, longBefore)).not.toBe('Expired');
    // ...while the real clock (today, past the 2026-09-20 end) says expired.
    expect(getExpiryLabel(board, new Date('2026-09-21T10:00:00'))).toBe('Expired');
  });
});
