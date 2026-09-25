import { describe, expect, it } from 'vitest';
import { Timeframe } from '@oybc/shared';
import { wizardSourceReference } from '../wizardDates';

/**
 * Owner ruling 2026-09-24 — the wizard resolves every board source against
 * the NEW board's window start (the same instant persist writes as
 * `startDate`), not "now".
 */
describe('wizardSourceReference', () => {
  const base = { customStartDate: '', customEndDate: '', weekStartDay: 'monday' as const };

  it("is the window's local start, not the reference instant", () => {
    const wed = new Date(2026, 8, 16, 15, 30); // Wed 2026-09-16 15:30 local
    expect(wizardSourceReference({ ...base, timeframe: Timeframe.WEEKLY }, wed)).toBe(
      '2026-09-14T00:00:00.000',
    );
    expect(wizardSourceReference({ ...base, timeframe: Timeframe.MONTHLY }, wed)).toBe(
      '2026-09-01T00:00:00.000',
    );
  });

  it('is the picked start for a CUSTOM range', () => {
    expect(
      wizardSourceReference({
        ...base,
        timeframe: Timeframe.CUSTOM,
        customStartDate: '2026-10-03',
        customEndDate: '2026-10-09',
      }),
    ).toBe('2026-10-03T00:00:00.000');
  });

  it('is undefined while a CUSTOM range has no dates (callers fall back to now)', () => {
    expect(wizardSourceReference({ ...base, timeframe: Timeframe.CUSTOM })).toBeUndefined();
  });
});
