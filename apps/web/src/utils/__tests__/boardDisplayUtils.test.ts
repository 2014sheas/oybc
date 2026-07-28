import { describe, expect, it } from 'vitest';
import { BoardStatus, Timeframe } from '@oybc/shared';
import { isBoardExpired, isBoardExpiringSoon, getExpiryLabel } from '../boardDisplayUtils';

/**
 * Regression: a CUSTOM-timeframe board with a user-specified end date must
 * behave like a timed board for expiry/display — it seals at that date too
 * (`isBoardSealable` only excludes INDEFINITE), so the display predicates must
 * agree. Only INDEFINITE / no-endDate boards are "never expired / No deadline".
 */
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();
const DAY = 24 * 60 * 60 * 1000;

describe('boardDisplayUtils — custom boards honor their end date', () => {
  it('isBoardExpired: custom board past its end date is expired', () => {
    expect(isBoardExpired({ timeframe: Timeframe.CUSTOM, endDate: iso(-DAY) })).toBe(true);
  });

  it('isBoardExpired: custom board before its end date is not expired', () => {
    expect(isBoardExpired({ timeframe: Timeframe.CUSTOM, endDate: iso(3 * DAY) })).toBe(false);
  });

  it('isBoardExpired: indefinite / no-endDate boards are never expired', () => {
    expect(isBoardExpired({ timeframe: Timeframe.INDEFINITE, endDate: iso(-DAY) })).toBe(false);
    expect(isBoardExpired({ timeframe: Timeframe.CUSTOM })).toBe(false);
  });

  it('getExpiryLabel: custom board shows a countdown, not "No deadline"', () => {
    expect(getExpiryLabel({ timeframe: Timeframe.CUSTOM, endDate: iso(3 * DAY) })).toBe('3 days left');
    expect(getExpiryLabel({ timeframe: Timeframe.CUSTOM, endDate: iso(-DAY) })).toBe('Expired');
    // Genuinely open-ended boards still read "No deadline".
    expect(getExpiryLabel({ timeframe: Timeframe.INDEFINITE, endDate: iso(3 * DAY) })).toBe('No deadline');
    expect(getExpiryLabel({ timeframe: Timeframe.CUSTOM })).toBe('No deadline');
  });

  it('isBoardExpiringSoon: active custom board within 24h is expiring soon', () => {
    expect(
      isBoardExpiringSoon({ status: BoardStatus.ACTIVE, timeframe: Timeframe.CUSTOM, endDate: iso(12 * 60 * 60 * 1000) }),
    ).toBe(true);
    // …but not one still days out, and not an indefinite board.
    expect(
      isBoardExpiringSoon({ status: BoardStatus.ACTIVE, timeframe: Timeframe.CUSTOM, endDate: iso(3 * DAY) }),
    ).toBe(false);
    expect(
      isBoardExpiringSoon({ status: BoardStatus.ACTIVE, timeframe: Timeframe.INDEFINITE, endDate: iso(12 * 60 * 60 * 1000) }),
    ).toBe(false);
  });
});
