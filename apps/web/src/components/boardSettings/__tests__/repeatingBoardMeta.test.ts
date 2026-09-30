import { describe, expect, it } from 'vitest';
import { Timeframe } from '@oybc/shared';
import { formatRenewsCaption, formatRepeatingBoardMeta } from '../repeatingBoardMeta';

describe('formatRenewsCaption', () => {
  it('renews daily for a DAILY board, regardless of week start', () => {
    expect(formatRenewsCaption(Timeframe.DAILY, 'monday')).toBe('renews daily');
    expect(formatRenewsCaption(Timeframe.DAILY, 'sunday')).toBe('renews daily');
  });

  it('renews on the week-start day for a WEEKLY board', () => {
    expect(formatRenewsCaption(Timeframe.WEEKLY, 'monday')).toBe('renews Mondays');
    expect(formatRenewsCaption(Timeframe.WEEKLY, 'sunday')).toBe('renews Sundays');
  });

  it('renews the 1st for a MONTHLY board, regardless of week start', () => {
    expect(formatRenewsCaption(Timeframe.MONTHLY, 'monday')).toBe('renews the 1st');
    expect(formatRenewsCaption(Timeframe.MONTHLY, 'sunday')).toBe('renews the 1st');
  });

  it('renews Jan 1 for a YEARLY board, regardless of week start', () => {
    expect(formatRenewsCaption(Timeframe.YEARLY, 'monday')).toBe('renews Jan 1');
    expect(formatRenewsCaption(Timeframe.YEARLY, 'sunday')).toBe('renews Jan 1');
  });
});

describe('formatRepeatingBoardMeta', () => {
  it('composes size · task-pool · renews-day for an active board', () => {
    expect(formatRepeatingBoardMeta(5, 9, Timeframe.WEEKLY, 'monday', true)).toBe(
      '5×5 board · 9-task pool · renews Mondays',
    );
  });

  it('replaces the renewal clause with "paused" for a paused board', () => {
    expect(formatRepeatingBoardMeta(3, 8, Timeframe.WEEKLY, 'monday', false)).toBe(
      '3×3 board · 8-task pool · paused',
    );
  });

  it('reflects a DAILY cadence', () => {
    expect(formatRepeatingBoardMeta(4, 16, Timeframe.DAILY, 'sunday', true)).toBe(
      '4×4 board · 16-task pool · renews daily',
    );
  });

  it('reflects a zero-task pool (still renders, never blank)', () => {
    expect(formatRepeatingBoardMeta(3, 0, Timeframe.MONTHLY, 'monday', true)).toBe(
      '3×3 board · 0-task pool · renews the 1st',
    );
  });
});
