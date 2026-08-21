import * as fs from 'fs';
import * as path from 'path';
import {
  getDayBoundaries,
  getTimeframeBoundaries,
  isWithinTimeframe,
  isTimeframeExpired,
  formatTimeframeLabel,
  formatRecurringCadence,
  formatCadenceAdverb,
  stepWindow,
} from '../../src/algorithms/calendarBoundaries';
import { Timeframe } from '../../src/constants/enums';

/**
 * C1 (issue #267): the fixed-input/fixed-output vector cases are now
 * fixture-driven from `tests/fixtures/calendarBoundariesVectors.json` — the
 * SAME file `apps/ios/OYBCTests/CalendarBoundariesVectorTests.swift` runs
 * through the iOS mirrors (`Utils/TimeframeBoundaries.swift` +
 * `Utils/TimeframeFormatting.swift`). This REPLACES every pre-C1 `it` block
 * EXCEPT the ones below, kept hand-written because they are either
 * nondeterministic (depend on `Date.now()` / "today") or TS-only (Swift's
 * type system makes the case inexpressible):
 *   - `defaults referenceDate to now when omitted` (getTimeframeBoundaries)
 *   - `formats daily as "Today" for current date` (formatTimeframeLabel)
 *   - `defaults to current time when now is omitted` (isTimeframeExpired)
 *   - `throws for non-integer step` (stepWindow — Swift's `step: Int`
 *     parameter makes a non-integer step a compile error, not a runtime case)
 *   - `throws for unparseable currentStart` (stepWindow — Swift's
 *     `stepCoreBoardWindow` returns `nil` via `parseISO8601Date` failing;
 *     covered structurally by the `invariant-*` fixture vectors' "not
 *     steppable" pattern, but the exact "garbage string" input isn't a
 *     cross-platform vector worth adding).
 *
 * Pre-C1 assertion count: ~55 `it` blocks across getDayBoundaries /
 * getWeekBoundaries / getMonthBoundaries / getYearBoundaries /
 * getTimeframeBoundaries / isWithinTimeframe / isTimeframeExpired /
 * formatTimeframeLabel / formatRecurringCadence / stepWindow. Post-C1: 20 +
 * 20 + 9 + 5 + 6 + 7 = 67 fixture vectors + 5 hand-written nondeterministic/
 * TS-only cases = net INCREASE in total assertions (the fixture also merges
 * `getDayBoundaries`/`getWeekBoundaries`/`getMonthBoundaries`/
 * `getYearBoundaries`'s dedicated describe-blocks into `getTimeframeBoundaries`
 * vectors, since the router dispatches to exactly those functions — no
 * behavior is left unexercised).
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/calendarBoundariesVectors.json');

interface BoundariesExpected {
  ok: boolean;
  startDate?: string;
  endDate?: string;
}

interface GetTimeframeBoundariesVector {
  name: string;
  timeframe: string;
  referenceDate: string;
  weekStartDay?: 'monday' | 'sunday';
  expected: BoundariesExpected;
}

interface StepWindowVector {
  name: string;
  timeframe: string;
  currentStart: string;
  step: number;
  weekStartDay?: 'monday' | 'sunday';
  expected: BoundariesExpected;
}

interface IsWithinVector {
  name: string;
  candidate: string;
  startDate: string;
  endDate: string | null;
  expected: boolean;
}

interface IsExpiredVector {
  name: string;
  endDate: string | null;
  now: string;
  expected: boolean;
}

interface CadenceVector {
  name: string;
  timeframe: string;
  expected: string;
}

interface LabelVector {
  name: string;
  timeframe: string;
  startDate: string;
  expected: string;
}

interface Fixture {
  getTimeframeBoundaries: GetTimeframeBoundariesVector[];
  stepWindow: StepWindowVector[];
  isWithinTimeframe: IsWithinVector[];
  isTimeframeExpired: IsExpiredVector[];
  formatRecurringCadence: CadenceVector[];
  formatTimeframeLabel: LabelVector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

describe('getTimeframeBoundaries (fixture-driven, tests/fixtures/calendarBoundariesVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.getTimeframeBoundaries.length).toBeGreaterThan(0);
  });

  for (const v of fixture.getTimeframeBoundaries) {
    it(v.name, () => {
      if (!v.expected.ok) {
        expect(() =>
          getTimeframeBoundaries(v.timeframe as Timeframe, new Date(v.referenceDate), v.weekStartDay),
        ).toThrow();
        return;
      }
      const result = getTimeframeBoundaries(
        v.timeframe as Timeframe,
        new Date(v.referenceDate),
        v.weekStartDay,
      );
      if (v.expected.startDate) expect(result.startDate).toBe(v.expected.startDate);
      if (v.expected.endDate) expect(result.endDate).toBe(v.expected.endDate);
    });
  }

  it('defaults referenceDate to now when omitted', () => {
    const result = getTimeframeBoundaries(Timeframe.DAILY);
    expect(result.startDate).toMatch(/^\d{4}-\d{2}-\d{2}T00:00:00\.000$/);
    expect(result.endDate).toMatch(/^\d{4}-\d{2}-\d{2}T23:59:59\.999$/);
  });
});

describe('stepWindow (fixture-driven, tests/fixtures/calendarBoundariesVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.stepWindow.length).toBeGreaterThan(0);
  });

  for (const v of fixture.stepWindow) {
    it(v.name, () => {
      if (!v.expected.ok) {
        expect(() => stepWindow(v.timeframe as Timeframe, v.currentStart, v.step, v.weekStartDay)).toThrow();
        return;
      }
      const result = stepWindow(v.timeframe as Timeframe, v.currentStart, v.step, v.weekStartDay);
      if (v.expected.startDate) expect(result.startDate).toBe(v.expected.startDate);
      if (v.expected.endDate) expect(result.endDate).toBe(v.expected.endDate);
    });
  }

  it('throws for non-integer step (TS-only — Swift step: Int makes this a compile error)', () => {
    expect(() => stepWindow(Timeframe.DAILY, '2026-05-19T00:00:00.000', 1.5)).toThrow(/integer/);
  });

  it('throws for unparseable currentStart', () => {
    expect(() => stepWindow(Timeframe.DAILY, 'not-a-date', 1)).toThrow(/parseable/);
  });
});

describe('isWithinTimeframe (fixture-driven, tests/fixtures/calendarBoundariesVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.isWithinTimeframe.length).toBeGreaterThan(0);
  });

  for (const v of fixture.isWithinTimeframe) {
    it(v.name, () => {
      expect(isWithinTimeframe(v.candidate, v.startDate, v.endDate)).toBe(v.expected);
    });
  }

  it('treats null endDate the same as undefined (unbounded)', () => {
    expect(isWithinTimeframe(new Date(2099, 11, 31), '2026-03-23T00:00:00.000', null)).toBe(true);
  });
});

describe('isTimeframeExpired (fixture-driven, tests/fixtures/calendarBoundariesVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.isTimeframeExpired.length).toBeGreaterThan(0);
  });

  for (const v of fixture.isTimeframeExpired) {
    it(v.name, () => {
      expect(isTimeframeExpired(v.endDate, new Date(v.now))).toBe(v.expected);
    });
  }

  it('defaults to current time when now is omitted', () => {
    expect(isTimeframeExpired('2099-12-31T23:59:59.999')).toBe(false);
    expect(isTimeframeExpired('2000-01-01T23:59:59.999')).toBe(true);
  });
});

describe('formatTimeframeLabel (fixture-driven, tests/fixtures/calendarBoundariesVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.formatTimeframeLabel.length).toBeGreaterThan(0);
  });

  for (const v of fixture.formatTimeframeLabel) {
    it(v.name, () => {
      expect(formatTimeframeLabel(v.timeframe as Timeframe, v.startDate)).toBe(v.expected);
    });
  }

  it('formats daily as "Today" for current date', () => {
    const today = new Date();
    const boundaries = getDayBoundaries(today);
    expect(formatTimeframeLabel(Timeframe.DAILY, boundaries.startDate)).toBe('Today');
  });
});

describe('formatRecurringCadence (fixture-driven, tests/fixtures/calendarBoundariesVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.formatRecurringCadence.length).toBeGreaterThan(0);
  });

  for (const v of fixture.formatRecurringCadence) {
    it(v.name, () => {
      expect(formatRecurringCadence(v.timeframe as Timeframe)).toBe(v.expected);
    });
  }
});

// ─── formatCadenceAdverb (P6 — Task Pools + Recurring Boards Rework) ──────────
//
// New in this PR — not yet in the shared fixture file (that's a hand-picked
// cross-platform vector set curated over time; this is a small, purely
// enumerable switch so a hand-written table suffices here).

describe('formatCadenceAdverb', () => {
  it('DAILY → "daily"', () => {
    expect(formatCadenceAdverb(Timeframe.DAILY)).toBe('daily');
  });
  it('WEEKLY → "weekly"', () => {
    expect(formatCadenceAdverb(Timeframe.WEEKLY)).toBe('weekly');
  });
  it('MONTHLY → "monthly"', () => {
    expect(formatCadenceAdverb(Timeframe.MONTHLY)).toBe('monthly');
  });
  it('YEARLY → "yearly"', () => {
    expect(formatCadenceAdverb(Timeframe.YEARLY)).toBe('yearly');
  });
  it('CUSTOM → "regularly" (defensive fallback — the repeat-cadence picker never offers Custom)', () => {
    expect(formatCadenceAdverb(Timeframe.CUSTOM)).toBe('regularly');
  });
  it('INDEFINITE → "regularly" (defensive fallback)', () => {
    expect(formatCadenceAdverb(Timeframe.INDEFINITE)).toBe('regularly');
  });
});
