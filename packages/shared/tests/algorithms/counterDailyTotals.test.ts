import { deriveCounterDailyTotals } from '../../src/algorithms/counterDailyTotals';
import type { TaskEvent } from '../../src/types/taskEvent';

const SOURCE = 'source-task-1';
const SEED_SENTINEL = '1970-01-01T00:00:00.000Z';

/**
 * Test timestamps are deliberately LOCAL-ISO (no trailing `Z`/offset), so
 * `new Date(str)` parses them as wall-clock local time directly — the day
 * bucketing is then identical no matter which timezone the test runner's
 * machine is in. Production `occurredAt`/`now` values are UTC-`Z` strings
 * written and read back on the SAME device, so the device-local day-key
 * derivation is equally deterministic there (see the module docstring).
 */
function ev(overrides: Partial<TaskEvent> & { occurredAt: string; delta: number }): TaskEvent {
  return {
    id: `evt-${Math.random()}`,
    userId: 'u1',
    taskId: SOURCE,
    kind: 'increment',
    createdAt: overrides.occurredAt,
    updatedAt: overrides.occurredAt,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

// "Now" pinned to 2026-07-20 (a Monday), mid-afternoon local time.
const NOW = '2026-07-20T15:00:00.000';

describe('deriveCounterDailyTotals', () => {
  it('returns exactly `days` zero-filled entries when there are no events', () => {
    const result = deriveCounterDailyTotals([], { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    expect(result.days).toHaveLength(7);
    expect(result.days.every((d) => d.total === 0)).toBe(true);
    expect(result.todayTotal).toBe(0);
  });

  it('orders days oldest-first, today last, as YYYY-MM-DD', () => {
    const result = deriveCounterDailyTotals([], { sourceTaskId: SOURCE, now: NOW, days: 3, seedSentinel: SEED_SENTINEL });
    expect(result.days.map((d) => d.dateISO)).toEqual(['2026-07-18', '2026-07-19', '2026-07-20']);
  });

  it('buckets multiple same-day events together', () => {
    const events = [
      ev({ occurredAt: '2026-07-20T09:00:00.000', delta: 5 }),
      ev({ occurredAt: '2026-07-20T18:30:00.000', delta: 3 }),
    ];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    const today = result.days[result.days.length - 1];
    expect(today.dateISO).toBe('2026-07-20');
    expect(today.total).toBe(8);
    expect(result.todayTotal).toBe(8);
  });

  it('keeps separate-day events in separate buckets', () => {
    const events = [
      ev({ occurredAt: '2026-07-18T09:00:00.000', delta: 4 }),
      ev({ occurredAt: '2026-07-19T09:00:00.000', delta: 6 }),
    ];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    const byDate = Object.fromEntries(result.days.map((d) => [d.dateISO, d.total]));
    expect(byDate['2026-07-18']).toBe(4);
    expect(byDate['2026-07-19']).toBe(6);
    expect(byDate['2026-07-20']).toBe(0);
  });

  it('zero-fills days with no activity', () => {
    const events = [ev({ occurredAt: '2026-07-20T09:00:00.000', delta: 2 })];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    // Every day but today should be zero.
    expect(result.days.slice(0, -1).every((d) => d.total === 0)).toBe(true);
  });

  it('excludes the seed-sentinel event even when it would otherwise land in the window', () => {
    // Use a sentinel value that DOES fall inside the trailing window, to prove
    // exclusion is by exact occurredAt match, not merely "too old to matter".
    const sentinel = '2026-07-20T00:00:01.000';
    const events = [
      ev({ occurredAt: sentinel, delta: 999 }),
      ev({ occurredAt: '2026-07-20T09:00:00.000', delta: 2 }),
    ];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: sentinel });
    expect(result.todayTotal).toBe(2);
  });

  it('excludes the real far-past SEED_EVENT_OCCURRED_AT sentinel from bucketing (out of window anyway)', () => {
    const events = [
      ev({ occurredAt: SEED_SENTINEL, delta: 1000 }),
      ev({ occurredAt: '2026-07-20T09:00:00.000', delta: 2 }),
    ];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    expect(result.days.reduce((sum, d) => sum + d.total, 0)).toBe(2);
  });

  it('sums negative deltas — a decrement event reduces a day total', () => {
    const events = [
      ev({ occurredAt: '2026-07-20T09:00:00.000', delta: 10 }),
      ev({ occurredAt: '2026-07-20T10:00:00.000', delta: -4 }),
    ];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    expect(result.todayTotal).toBe(6);
  });

  it('excludes events outside the trailing window (7-day edge)', () => {
    // 7-day window ending 2026-07-20 starts 2026-07-14. An event on
    // 2026-07-13 (8 days back) must be excluded; one on 2026-07-14 (exactly
    // the window's oldest day) must be included.
    const events = [
      ev({ occurredAt: '2026-07-13T09:00:00.000', delta: 100 }),
      ev({ occurredAt: '2026-07-14T09:00:00.000', delta: 7 }),
    ];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    expect(result.days[0].dateISO).toBe('2026-07-14');
    expect(result.days[0].total).toBe(7);
    expect(result.days.reduce((sum, d) => sum + d.total, 0)).toBe(7);
  });

  it('ignores events for a different task', () => {
    const events = [ev({ taskId: 'other-task', occurredAt: '2026-07-20T09:00:00.000', delta: 50 })];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    expect(result.todayTotal).toBe(0);
  });

  it('ignores non-increment (completion) events', () => {
    const events = [ev({ occurredAt: '2026-07-20T09:00:00.000', delta: 50, kind: 'completion' })];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    expect(result.todayTotal).toBe(0);
  });

  it('ignores soft-deleted events', () => {
    const events = [ev({ occurredAt: '2026-07-20T09:00:00.000', delta: 50, isDeleted: true })];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    expect(result.todayTotal).toBe(0);
  });

  it('does not special-case pre-amount events (delta: 1) — they sum in normally', () => {
    const events = [
      ev({ occurredAt: '2026-07-20T09:00:00.000', delta: 1 }),
      ev({ occurredAt: '2026-07-20T10:00:00.000', delta: 1 }),
      ev({ occurredAt: '2026-07-20T11:00:00.000', delta: 1 }),
    ];
    const result = deriveCounterDailyTotals(events, { sourceTaskId: SOURCE, now: NOW, days: 7, seedSentinel: SEED_SENTINEL });
    expect(result.todayTotal).toBe(3);
  });

  it('throws for a non-positive days value', () => {
    expect(() => deriveCounterDailyTotals([], { sourceTaskId: SOURCE, now: NOW, days: 0, seedSentinel: SEED_SENTINEL })).toThrow();
    expect(() => deriveCounterDailyTotals([], { sourceTaskId: SOURCE, now: NOW, days: -1, seedSentinel: SEED_SENTINEL })).toThrow();
  });

  it('throws for a non-integer days value', () => {
    expect(() => deriveCounterDailyTotals([], { sourceTaskId: SOURCE, now: NOW, days: 2.5, seedSentinel: SEED_SENTINEL })).toThrow();
  });
});
