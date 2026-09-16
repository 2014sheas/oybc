import { describe, expect, it } from 'vitest';
import { AchievementTrigger, Timeframe, type Board, type WeekStartDay } from '@oybc/shared';
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

  it('computes normally once ready', () => {
    // No boards ⇒ 0 either way; the point is that `ready` is what gates,
    // and a ready call delegates to computeStreak rather than short-circuiting.
    expect(gatedStreak(true, Timeframe.DAILY, AchievementTrigger.GREENLOG, [] as Board[], MONDAY, new Date()))
      .toBe(0);
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

  it('two calls with one pinned instant always agree', () => {
    const pinned = new Date('2026-09-20T10:00:00');
    expect(isBoardExpiringSoon(board, pinned)).toBe(isBoardExpiringSoon(board, pinned));
    expect(getExpiryLabel(board, pinned)).toBe(getExpiryLabel(board, pinned));
  });
});
