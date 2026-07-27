import { describe, expect, it } from 'vitest';
import { Timeframe } from '@oybc/shared';
import { buildEditDatesPatch } from '../BoardEditPanel';

/**
 * Direct branch coverage for the Save patch's preserve-vs-rewindow decision
 * (review Important: this logic previously lived inline in the component
 * with zero direct coverage — an inverted boolean would have silently
 * reintroduced the progress-reset-on-edit bug).
 */
const base = {
  origStart: '2026-07-01',
  origEnd: '2026-07-31',
  customStartDate: '2026-07-01',
  customEndDate: '2026-07-31',
  computedBoundaries: { startDate: 'CB-START', endDate: 'CB-END' },
  now: new Date(2026, 6, 27, 15, 30), // deterministic "today"
};

describe('buildEditDatesPatch — preserve vs rewindow', () => {
  it('metadata-only save (unchanged timeframe + dates) omits BOTH fields — the window survives', () => {
    for (const tf of [
      Timeframe.DAILY,
      Timeframe.WEEKLY,
      Timeframe.MONTHLY,
      Timeframe.YEARLY,
      Timeframe.INDEFINITE,
      Timeframe.CUSTOM,
    ]) {
      const out = buildEditDatesPatch({ ...base, boardTimeframe: tf, formTimeframe: tf });
      expect(out, `timeframe ${tf} must preserve`).toEqual({});
    }
  });

  it('unchanged INDEFINITE board is NOT re-anchored to today (the original bug)', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.INDEFINITE,
      formTimeframe: Timeframe.INDEFINITE,
    });
    expect(out.startDate).toBeUndefined();
    expect(out.endDate).toBeUndefined();
  });

  it('timeframe CHANGE to a core timeframe re-windows via computed boundaries', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.WEEKLY,
      formTimeframe: Timeframe.DAILY,
    });
    expect(out).toEqual({ startDate: 'CB-START', endDate: 'CB-END' });
  });

  it('timeframe CHANGE to INDEFINITE anchors start to today and clears the deadline', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.WEEKLY,
      formTimeframe: Timeframe.INDEFINITE,
    });
    // startDate = local midnight of the injected "today"; endDate = explicit null (clear).
    expect(out.startDate).toContain('2026-07-27T00:00:00');
    expect(out.endDate).toBeNull();
  });

  it('timeframe CHANGE to CUSTOM uses the picked dates', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.WEEKLY,
      formTimeframe: Timeframe.CUSTOM,
      customStartDate: '2026-07-10',
      customEndDate: '2026-07-20',
    });
    expect(out.startDate).toContain('2026-07-10T00:00:00');
    expect(out.endDate).toContain('2026-07-20T23:59:59');
  });

  it('unchanged CUSTOM timeframe with EDITED dates applies the new window', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.CUSTOM,
      formTimeframe: Timeframe.CUSTOM,
      customStartDate: '2026-07-05', // differs from origStart
    });
    expect(out.startDate).toContain('2026-07-05T00:00:00');
    expect(out.endDate).toContain('2026-07-31T23:59:59');
  });

  it('unchanged CUSTOM with UNTOUCHED dates preserves (dates equal to orig)', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.CUSTOM,
      formTimeframe: Timeframe.CUSTOM,
    });
    expect(out).toEqual({});
  });

  it('date edits on a NON-custom timeframe are ignored (form state cannot re-window a core board)', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.WEEKLY,
      formTimeframe: Timeframe.WEEKLY,
      customStartDate: '2026-07-05', // stale picker state — must not leak
    });
    expect(out).toEqual({});
  });
});
