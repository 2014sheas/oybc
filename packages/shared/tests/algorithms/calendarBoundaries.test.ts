import {
  getDayBoundaries,
  getWeekBoundaries,
  getMonthBoundaries,
  getYearBoundaries,
  getTimeframeBoundaries,
  isWithinTimeframe,
  isTimeframeExpired,
  formatTimeframeLabel,
  formatRecurringCadence,
  stepWindow,
} from '../../src/algorithms/calendarBoundaries';
import { Timeframe } from '../../src/constants/enums';

// ─── Daily Boundaries ─────────────────────────────────────────────────────────

describe('getDayBoundaries', () => {
  it('returns same-day 00:00 to 23:59:59.999', () => {
    const result = getDayBoundaries(new Date(2026, 2, 15, 14, 30)); // Mar 15 2:30 PM
    expect(result.startDate).toBe('2026-03-15T00:00:00.000');
    expect(result.endDate).toBe('2026-03-15T23:59:59.999');
  });

  it('handles midnight exactly', () => {
    const result = getDayBoundaries(new Date(2026, 0, 1, 0, 0, 0, 0)); // Jan 1 midnight
    expect(result.startDate).toBe('2026-01-01T00:00:00.000');
    expect(result.endDate).toBe('2026-01-01T23:59:59.999');
  });

  it('handles end of day', () => {
    const result = getDayBoundaries(new Date(2026, 11, 31, 23, 59, 59, 999)); // Dec 31 end
    expect(result.startDate).toBe('2026-12-31T00:00:00.000');
    expect(result.endDate).toBe('2026-12-31T23:59:59.999');
  });
});

// ─── Weekly Boundaries ────────────────────────────────────────────────────────

describe('getWeekBoundaries', () => {
  describe('Monday start', () => {
    it('Wednesday → Mon-Sun of that week', () => {
      // Wed Mar 25 2026
      const result = getWeekBoundaries(new Date(2026, 2, 25), 'monday');
      expect(result.startDate).toBe('2026-03-23T00:00:00.000'); // Monday
      expect(result.endDate).toBe('2026-03-29T23:59:59.999');   // Sunday
    });

    it('Monday → same week', () => {
      const result = getWeekBoundaries(new Date(2026, 2, 23), 'monday');
      expect(result.startDate).toBe('2026-03-23T00:00:00.000');
      expect(result.endDate).toBe('2026-03-29T23:59:59.999');
    });

    it('Sunday → same week (ends that day)', () => {
      const result = getWeekBoundaries(new Date(2026, 2, 29), 'monday');
      expect(result.startDate).toBe('2026-03-23T00:00:00.000');
      expect(result.endDate).toBe('2026-03-29T23:59:59.999');
    });

    it('crosses month boundary', () => {
      // Fri Mar 27 2026 — week is Mon Mar 23 to Sun Mar 29
      // But let's pick a date where the week crosses months
      // Thu Jan 1 2026 — week is Mon Dec 29 2025 to Sun Jan 4 2026
      const result = getWeekBoundaries(new Date(2026, 0, 1), 'monday');
      expect(result.startDate).toBe('2025-12-29T00:00:00.000');
      expect(result.endDate).toBe('2026-01-04T23:59:59.999');
    });
  });

  describe('Sunday start', () => {
    it('Wednesday → Sun-Sat of that week', () => {
      // Wed Mar 25 2026
      const result = getWeekBoundaries(new Date(2026, 2, 25), 'sunday');
      expect(result.startDate).toBe('2026-03-22T00:00:00.000'); // Sunday
      expect(result.endDate).toBe('2026-03-28T23:59:59.999');   // Saturday
    });

    it('Sunday → same week (starts that day)', () => {
      const result = getWeekBoundaries(new Date(2026, 2, 22), 'sunday');
      expect(result.startDate).toBe('2026-03-22T00:00:00.000');
      expect(result.endDate).toBe('2026-03-28T23:59:59.999');
    });

    it('Saturday → same week (ends that day)', () => {
      const result = getWeekBoundaries(new Date(2026, 2, 28), 'sunday');
      expect(result.startDate).toBe('2026-03-22T00:00:00.000');
      expect(result.endDate).toBe('2026-03-28T23:59:59.999');
    });
  });
});

// ─── Monthly Boundaries ──────────────────────────────────────────────────────

describe('getMonthBoundaries', () => {
  it('mid-month → 1st to last day', () => {
    const result = getMonthBoundaries(new Date(2026, 2, 15)); // Mar 15
    expect(result.startDate).toBe('2026-03-01T00:00:00.000');
    expect(result.endDate).toBe('2026-03-31T23:59:59.999');
  });

  it('handles February non-leap year (28 days)', () => {
    const result = getMonthBoundaries(new Date(2026, 1, 10)); // Feb 10, 2026
    expect(result.startDate).toBe('2026-02-01T00:00:00.000');
    expect(result.endDate).toBe('2026-02-28T23:59:59.999');
  });

  it('handles February leap year (29 days)', () => {
    const result = getMonthBoundaries(new Date(2028, 1, 15)); // Feb 15, 2028 (leap)
    expect(result.startDate).toBe('2028-02-01T00:00:00.000');
    expect(result.endDate).toBe('2028-02-29T23:59:59.999');
  });

  it('handles 30-day months', () => {
    const result = getMonthBoundaries(new Date(2026, 3, 20)); // Apr 20
    expect(result.startDate).toBe('2026-04-01T00:00:00.000');
    expect(result.endDate).toBe('2026-04-30T23:59:59.999');
  });

  it('handles December', () => {
    const result = getMonthBoundaries(new Date(2026, 11, 25)); // Dec 25
    expect(result.startDate).toBe('2026-12-01T00:00:00.000');
    expect(result.endDate).toBe('2026-12-31T23:59:59.999');
  });
});

// ─── Yearly Boundaries ───────────────────────────────────────────────────────

describe('getYearBoundaries', () => {
  it('any date → Jan 1 to Dec 31', () => {
    const result = getYearBoundaries(new Date(2026, 6, 4)); // Jul 4
    expect(result.startDate).toBe('2026-01-01T00:00:00.000');
    expect(result.endDate).toBe('2026-12-31T23:59:59.999');
  });

  it('handles Jan 1', () => {
    const result = getYearBoundaries(new Date(2026, 0, 1));
    expect(result.startDate).toBe('2026-01-01T00:00:00.000');
    expect(result.endDate).toBe('2026-12-31T23:59:59.999');
  });

  it('handles Dec 31', () => {
    const result = getYearBoundaries(new Date(2026, 11, 31));
    expect(result.startDate).toBe('2026-01-01T00:00:00.000');
    expect(result.endDate).toBe('2026-12-31T23:59:59.999');
  });
});

// ─── getTimeframeBoundaries (router) ─────────────────────────────────────────

describe('getTimeframeBoundaries', () => {
  it('routes DAILY correctly', () => {
    const result = getTimeframeBoundaries(Timeframe.DAILY, new Date(2026, 2, 15));
    expect(result.startDate).toBe('2026-03-15T00:00:00.000');
    expect(result.endDate).toBe('2026-03-15T23:59:59.999');
  });

  it('routes WEEKLY with monday start', () => {
    const result = getTimeframeBoundaries(Timeframe.WEEKLY, new Date(2026, 2, 25), 'monday');
    expect(result.startDate).toBe('2026-03-23T00:00:00.000');
    expect(result.endDate).toBe('2026-03-29T23:59:59.999');
  });

  it('routes WEEKLY with sunday start', () => {
    const result = getTimeframeBoundaries(Timeframe.WEEKLY, new Date(2026, 2, 25), 'sunday');
    expect(result.startDate).toBe('2026-03-22T00:00:00.000');
    expect(result.endDate).toBe('2026-03-28T23:59:59.999');
  });

  it('defaults weekStartDay to monday', () => {
    const result = getTimeframeBoundaries(Timeframe.WEEKLY, new Date(2026, 2, 25));
    expect(result.startDate).toBe('2026-03-23T00:00:00.000');
  });

  it('routes MONTHLY correctly', () => {
    const result = getTimeframeBoundaries(Timeframe.MONTHLY, new Date(2026, 2, 15));
    expect(result.startDate).toBe('2026-03-01T00:00:00.000');
    expect(result.endDate).toBe('2026-03-31T23:59:59.999');
  });

  it('routes YEARLY correctly', () => {
    const result = getTimeframeBoundaries(Timeframe.YEARLY, new Date(2026, 6, 4));
    expect(result.startDate).toBe('2026-01-01T00:00:00.000');
    expect(result.endDate).toBe('2026-12-31T23:59:59.999');
  });

  it('throws for CUSTOM timeframe', () => {
    expect(() => getTimeframeBoundaries(Timeframe.CUSTOM)).toThrow();
  });

  it('throws for INDEFINITE timeframe', () => {
    expect(() => getTimeframeBoundaries(Timeframe.INDEFINITE)).toThrow();
  });

  it('defaults referenceDate to now when omitted', () => {
    const result = getTimeframeBoundaries(Timeframe.DAILY);
    // Should contain today's date — just verify it returns valid boundaries
    expect(result.startDate).toMatch(/^\d{4}-\d{2}-\d{2}T00:00:00\.000$/);
    expect(result.endDate).toMatch(/^\d{4}-\d{2}-\d{2}T23:59:59\.999$/);
  });
});

// ─── isWithinTimeframe ───────────────────────────────────────────────────────

describe('isWithinTimeframe', () => {
  const start = '2026-03-23T00:00:00.000';
  const end = '2026-03-29T23:59:59.999';

  it('returns true for date inside range', () => {
    expect(isWithinTimeframe(new Date(2026, 2, 25, 12, 0), start, end)).toBe(true);
  });

  it('returns true for date at start boundary', () => {
    expect(isWithinTimeframe(new Date(2026, 2, 23, 0, 0, 0, 0), start, end)).toBe(true);
  });

  it('returns true for date at end boundary', () => {
    expect(isWithinTimeframe(new Date(2026, 2, 29, 23, 59, 59, 999), start, end)).toBe(true);
  });

  it('returns false for date before range', () => {
    expect(isWithinTimeframe(new Date(2026, 2, 22, 23, 59), start, end)).toBe(false);
  });

  it('returns false for date after range', () => {
    expect(isWithinTimeframe(new Date(2026, 2, 30, 0, 0), start, end)).toBe(false);
  });

  it('accepts ISO string as date parameter', () => {
    expect(isWithinTimeframe('2026-03-25T12:00:00.000', start, end)).toBe(true);
    expect(isWithinTimeframe('2026-03-30T00:00:00.000', start, end)).toBe(false);
  });

  // Indefinite boards: an absent endDate means an unbounded window [start, ∞).
  describe('unbounded window (indefinite board — no endDate)', () => {
    it('returns true for any date at or after start when endDate is undefined', () => {
      expect(isWithinTimeframe(new Date(2026, 2, 25), start, undefined)).toBe(true);
      expect(isWithinTimeframe(new Date(2030, 0, 1), start)).toBe(true);
    });

    it('returns true at the start boundary with no endDate', () => {
      expect(isWithinTimeframe(new Date(2026, 2, 23, 0, 0, 0, 0), start, undefined)).toBe(true);
    });

    it('returns false before start even with no endDate', () => {
      expect(isWithinTimeframe(new Date(2026, 2, 22), start, undefined)).toBe(false);
    });

    it('treats null endDate the same as undefined (unbounded)', () => {
      expect(isWithinTimeframe(new Date(2099, 11, 31), start, null)).toBe(true);
    });
  });
});

// ─── isTimeframeExpired ──────────────────────────────────────────────────────

describe('isTimeframeExpired', () => {
  it('returns true when now is after endDate', () => {
    expect(isTimeframeExpired('2026-03-29T23:59:59.999', new Date(2026, 2, 30, 0, 0))).toBe(true);
  });

  it('returns false when now is before endDate', () => {
    expect(isTimeframeExpired('2026-03-29T23:59:59.999', new Date(2026, 2, 28, 12, 0))).toBe(false);
  });

  it('returns false when now is exactly at endDate', () => {
    expect(isTimeframeExpired('2026-03-29T23:59:59.999', new Date(2026, 2, 29, 23, 59, 59, 999))).toBe(false);
  });

  it('returns true one millisecond after endDate', () => {
    const endDate = '2026-03-29T23:59:59.999';
    const oneAfter = new Date(2026, 2, 30, 0, 0, 0, 0);
    expect(isTimeframeExpired(endDate, oneAfter)).toBe(true);
  });

  it('defaults to current time when now is omitted', () => {
    // Far future date should not be expired
    expect(isTimeframeExpired('2099-12-31T23:59:59.999')).toBe(false);
    // Far past date should be expired
    expect(isTimeframeExpired('2000-01-01T23:59:59.999')).toBe(true);
  });

  it('returns false when endDate is undefined (indefinite board never expires)', () => {
    expect(isTimeframeExpired(undefined, new Date(2099, 0, 1))).toBe(false);
    expect(isTimeframeExpired(null, new Date(2099, 0, 1))).toBe(false);
  });
});

// ─── formatTimeframeLabel ────────────────────────────────────────────────────

describe('formatTimeframeLabel', () => {
  it('formats daily as "Today" for current date', () => {
    const today = new Date();
    const boundaries = getDayBoundaries(today);
    expect(formatTimeframeLabel(Timeframe.DAILY, boundaries.startDate)).toBe('Today');
  });

  it('formats daily with date for non-today', () => {
    const label = formatTimeframeLabel(Timeframe.DAILY, '2026-03-15T00:00:00.000');
    expect(label).toBe('Mar 15, 2026');
  });

  it('formats weekly with date range', () => {
    const label = formatTimeframeLabel(Timeframe.WEEKLY, '2026-03-23T00:00:00.000');
    expect(label).toBe('Week of Mar 23 – 29, 2026');
  });

  it('formats weekly across month boundary', () => {
    const label = formatTimeframeLabel(Timeframe.WEEKLY, '2025-12-29T00:00:00.000');
    expect(label).toBe('Week of Dec 29 – Jan 4');
  });

  it('formats monthly with month and year', () => {
    const label = formatTimeframeLabel(Timeframe.MONTHLY, '2026-03-01T00:00:00.000');
    expect(label).toBe('March 2026');
  });

  it('formats yearly with year', () => {
    const label = formatTimeframeLabel(Timeframe.YEARLY, '2026-01-01T00:00:00.000');
    expect(label).toBe('2026');
  });

  it('formats custom as "Custom"', () => {
    const label = formatTimeframeLabel(Timeframe.CUSTOM, '2026-03-01T00:00:00.000');
    expect(label).toBe('Custom');
  });

  it('formats indefinite as "Ongoing"', () => {
    const label = formatTimeframeLabel(Timeframe.INDEFINITE, '2026-03-01T00:00:00.000');
    expect(label).toBe('Ongoing');
  });
});

// ─── formatRecurringCadence ──────────────────────────────────────────────────

describe('formatRecurringCadence', () => {
  it('returns "Every day" for DAILY', () => {
    expect(formatRecurringCadence(Timeframe.DAILY)).toBe('Every day');
  });
  it('returns "Every week" for WEEKLY', () => {
    expect(formatRecurringCadence(Timeframe.WEEKLY)).toBe('Every week');
  });
  it('returns "Every month" for MONTHLY', () => {
    expect(formatRecurringCadence(Timeframe.MONTHLY)).toBe('Every month');
  });
  it('returns "Every year" for YEARLY', () => {
    expect(formatRecurringCadence(Timeframe.YEARLY)).toBe('Every year');
  });
  it('returns "Custom" for CUSTOM (defensive — production excludes it)', () => {
    expect(formatRecurringCadence(Timeframe.CUSTOM)).toBe('Custom');
  });
  it('returns "Ongoing" for INDEFINITE (defensive — production excludes it)', () => {
    expect(formatRecurringCadence(Timeframe.INDEFINITE)).toBe('Ongoing');
  });
});

// ─── Step Window (pagination) ────────────────────────────────────────────────

describe('stepWindow', () => {
  // DAILY ─────────────────────────────────────────────────────────────────
  describe('DAILY', () => {
    it('+1 from Tuesday gives Wednesday', () => {
      const next = stepWindow(Timeframe.DAILY, '2026-05-19T00:00:00.000', 1);
      expect(next.startDate).toBe('2026-05-20T00:00:00.000');
      expect(next.endDate).toBe('2026-05-20T23:59:59.999');
    });
    it('-1 from Tuesday gives Monday', () => {
      const prev = stepWindow(Timeframe.DAILY, '2026-05-19T00:00:00.000', -1);
      expect(prev.startDate).toBe('2026-05-18T00:00:00.000');
    });
    it('+1 crossing month boundary (May 31 → Jun 1)', () => {
      const next = stepWindow(Timeframe.DAILY, '2026-05-31T00:00:00.000', 1);
      expect(next.startDate).toBe('2026-06-01T00:00:00.000');
    });
    it('+1 crossing year boundary (Dec 31 → Jan 1)', () => {
      const next = stepWindow(Timeframe.DAILY, '2026-12-31T00:00:00.000', 1);
      expect(next.startDate).toBe('2027-01-01T00:00:00.000');
    });
    it('+5 accumulates correctly', () => {
      const result = stepWindow(Timeframe.DAILY, '2026-05-19T00:00:00.000', 5);
      expect(result.startDate).toBe('2026-05-24T00:00:00.000');
    });
  });

  // WEEKLY ────────────────────────────────────────────────────────────────
  describe('WEEKLY', () => {
    it('+1 from a Monday-start week gives the next Monday week', () => {
      const next = stepWindow(
        Timeframe.WEEKLY,
        '2026-05-18T00:00:00.000', // Monday May 18
        1,
        'monday',
      );
      expect(next.startDate).toBe('2026-05-25T00:00:00.000');
      expect(next.endDate).toBe('2026-05-31T23:59:59.999');
    });
    it('-1 from Mon May 18 gives Mon May 11', () => {
      const prev = stepWindow(Timeframe.WEEKLY, '2026-05-18T00:00:00.000', -1, 'monday');
      expect(prev.startDate).toBe('2026-05-11T00:00:00.000');
    });
    it('honours sunday week-start when stepping across months', () => {
      const next = stepWindow(
        Timeframe.WEEKLY,
        '2026-05-31T00:00:00.000', // Sun May 31
        1,
        'sunday',
      );
      expect(next.startDate).toBe('2026-06-07T00:00:00.000');
    });
    it('+2 jumps two weeks at once', () => {
      const result = stepWindow(Timeframe.WEEKLY, '2026-05-18T00:00:00.000', 2, 'monday');
      expect(result.startDate).toBe('2026-06-01T00:00:00.000');
    });
  });

  // MONTHLY ───────────────────────────────────────────────────────────────
  describe('MONTHLY', () => {
    it('+1 from Jan gives Feb (handles short Feb)', () => {
      const next = stepWindow(Timeframe.MONTHLY, '2026-01-01T00:00:00.000', 1);
      expect(next.startDate).toBe('2026-02-01T00:00:00.000');
      expect(next.endDate).toBe('2026-02-28T23:59:59.999');
    });
    it('+1 from Feb gives Mar with full 31-day endDate', () => {
      const next = stepWindow(Timeframe.MONTHLY, '2026-02-01T00:00:00.000', 1);
      expect(next.startDate).toBe('2026-03-01T00:00:00.000');
      expect(next.endDate).toBe('2026-03-31T23:59:59.999');
    });
    it('leap year — Feb 2028 has 29 days', () => {
      const next = stepWindow(Timeframe.MONTHLY, '2028-01-01T00:00:00.000', 1);
      expect(next.endDate).toBe('2028-02-29T23:59:59.999');
    });
    it('+1 from Dec rolls year', () => {
      const next = stepWindow(Timeframe.MONTHLY, '2026-12-01T00:00:00.000', 1);
      expect(next.startDate).toBe('2027-01-01T00:00:00.000');
    });
    it('-1 from Jan rolls year backward', () => {
      const prev = stepWindow(Timeframe.MONTHLY, '2026-01-01T00:00:00.000', -1);
      expect(prev.startDate).toBe('2025-12-01T00:00:00.000');
    });
    it('+13 accumulates a year + a month', () => {
      const result = stepWindow(Timeframe.MONTHLY, '2026-01-01T00:00:00.000', 13);
      expect(result.startDate).toBe('2027-02-01T00:00:00.000');
    });
  });

  // YEARLY ────────────────────────────────────────────────────────────────
  describe('YEARLY', () => {
    it('+1 gives the next year', () => {
      const next = stepWindow(Timeframe.YEARLY, '2026-01-01T00:00:00.000', 1);
      expect(next.startDate).toBe('2027-01-01T00:00:00.000');
      expect(next.endDate).toBe('2027-12-31T23:59:59.999');
    });
    it('-1 gives the previous year', () => {
      const prev = stepWindow(Timeframe.YEARLY, '2026-01-01T00:00:00.000', -1);
      expect(prev.startDate).toBe('2025-01-01T00:00:00.000');
    });
  });

  // Invariants ───────────────────────────────────────────────────────────
  describe('invariants', () => {
    it('step 0 returns the same window (boundaries from the input date)', () => {
      const result = stepWindow(Timeframe.DAILY, '2026-05-19T00:00:00.000', 0);
      expect(result.startDate).toBe('2026-05-19T00:00:00.000');
    });
    it('throws for CUSTOM timeframe', () => {
      expect(() =>
        stepWindow(Timeframe.CUSTOM, '2026-05-19T00:00:00.000', 1),
      ).toThrow(/custom/i);
    });
    it('throws for INDEFINITE timeframe', () => {
      expect(() =>
        stepWindow(Timeframe.INDEFINITE, '2026-05-19T00:00:00.000', 1),
      ).toThrow(/indefinite/i);
    });
    it('throws for non-integer step', () => {
      expect(() =>
        stepWindow(Timeframe.DAILY, '2026-05-19T00:00:00.000', 1.5),
      ).toThrow(/integer/);
    });
    it('throws for unparseable currentStart', () => {
      expect(() =>
        stepWindow(Timeframe.DAILY, 'not-a-date', 1),
      ).toThrow(/parseable/);
    });
  });
});
