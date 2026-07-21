import type { TaskEvent } from '../types/taskEvent';

/**
 * counterDailyTotals.ts — derives a counter's trailing daily totals (the
 * Counter Detail 7-day sparkline + "Today" stat) from its source task's raw
 * `task_events` stream.
 *
 * Part of the R2 Counters UX refresh (docs/SHARED_COUNTERS.md §Counters UX
 * refresh → "P4 data — UI built now, fed later" — the sparkline and Today
 * are fed for REAL here; Streak / Best week / Recent weeks stay stubbed
 * pending genuine P4 rollup storage).
 *
 * Every counter log is a single `TaskEvent{kind:'increment', delta}` row on
 * the SOURCE task only (derived/linked tasks are carved out — they own no
 * events). So a counter's whole history is one event stream keyed by
 * `taskId === sourceTaskId`. Seed/backfill events (P5 hub-born counters'
 * starting-count seed) carry the far-past sentinel `occurredAt` and are
 * excluded from day-bucketing — they represent a one-time starting balance,
 * not an activity occurrence on any real day.
 *
 * Pure and fully deterministic: every notion of "now" flows through the
 * `now` parameter, never `Date.now()`/`new Date()` with no argument.
 */

/**
 * A single day's bucketed total.
 */
export interface CounterDailyTotal {
  /**
   * The bucket's local calendar day, as `YYYY-MM-DD` (device-local
   * calendar fields — see the day-key derivation note on
   * {@link deriveCounterDailyTotals}). Not a full ISO8601 timestamp; the
   * `dateISO` name matches the field's role (a date, expressed in ISO
   * `YYYY-MM-DD` form) without implying a time-of-day component.
   */
  dateISO: string;
  /** Sum of `delta` for increment events whose `occurredAt` falls on this day. */
  total: number;
}

export interface CounterDailyTotalsResult {
  /**
   * Exactly `opts.days` entries, oldest first, today last, zero-filled for
   * any day with no activity.
   */
  days: CounterDailyTotal[];
  /** Convenience: `days[days.length - 1].total` (today's bucket). */
  todayTotal: number;
}

export interface DeriveCounterDailyTotalsOptions {
  /** Only events with this `taskId` are counted — the counter's source task. */
  sourceTaskId: string;
  /** ISO8601 "now" — every day boundary is computed relative to this. */
  now: string;
  /** Window size in trailing days (inclusive of today). Must be a positive integer. */
  days: number;
  /**
   * The seed-event sentinel `occurredAt` (the shared `SEED_EVENT_OCCURRED_AT`
   * constant, `src/algorithms/taskEvents.ts`) — events stamped with this
   * exact value are backfilled starting-count seeds, not real activity, and
   * are excluded from bucketing.
   */
  seedSentinel: string;
}

/**
 * Local calendar-day key for a timestamp, as `YYYY-MM-DD`.
 *
 * Uses the JS `Date` object's LOCAL getters (`getFullYear`/`getMonth`/
 * `getDate`), i.e. the device's local timezone — the same convention
 * `calendarBoundaries.ts`'s `startOfDay`/`toLocalISO` use for "today" /
 * "this week" concepts. Two events during the same wall-clock day bucket
 * together regardless of what timezone offset their ISO string carries,
 * because `new Date(iso)` is parsed to an absolute instant and then read
 * back out in the CALLING device's local time — this is intentional: a
 * user always sees "today"/"this week" relative to their own clock, not UTC.
 */
function localDayKey(date: Date): string {
  const y = date.getFullYear();
  const mo = String(date.getMonth() + 1).padStart(2, '0');
  const da = String(date.getDate()).padStart(2, '0');
  return `${y}-${mo}-${da}`;
}

/**
 * Derives a counter's trailing daily totals from its source task's raw
 * increment events.
 *
 * Filters to: `taskId === sourceTaskId`, `kind === 'increment'`,
 * `!isDeleted`, and `occurredAt !== seedSentinel`. Pre-amount-logging events
 * (from before R2) carry `delta: ±1` — no special-casing needed, they sum
 * in exactly like any other increment.
 *
 * @param events All candidate events (typically the source task's full
 *   non-deleted event set, or a superset — filtering is internal).
 * @param opts   See {@link DeriveCounterDailyTotalsOptions}.
 * @returns `{ days, todayTotal }` — see {@link CounterDailyTotalsResult}.
 * @throws If `opts.days` is not a positive integer.
 */
export function deriveCounterDailyTotals(
  events: TaskEvent[],
  opts: DeriveCounterDailyTotalsOptions,
): CounterDailyTotalsResult {
  const { sourceTaskId, now, days, seedSentinel } = opts;
  if (!Number.isInteger(days) || days <= 0) {
    throw new Error(`deriveCounterDailyTotals: days must be a positive integer, got ${days}`);
  }

  const nowDate = new Date(now);

  // Build the ordered trailing window of day keys — oldest first, today last.
  const dayKeys: string[] = [];
  for (let i = days - 1; i >= 0; i -= 1) {
    const bucketDate = new Date(nowDate.getFullYear(), nowDate.getMonth(), nowDate.getDate() - i);
    dayKeys.push(localDayKey(bucketDate));
  }
  const todayKey = dayKeys[dayKeys.length - 1];

  const totalsByDay = new Map<string, number>(dayKeys.map((key) => [key, 0]));

  for (const event of events) {
    if (event.taskId !== sourceTaskId) continue;
    if (event.kind !== 'increment') continue;
    if (event.isDeleted) continue;
    if (event.occurredAt === seedSentinel) continue;

    const key = localDayKey(new Date(event.occurredAt));
    if (!totalsByDay.has(key)) continue; // outside the trailing window

    totalsByDay.set(key, (totalsByDay.get(key) ?? 0) + (event.delta ?? 0));
  }

  const daysResult: CounterDailyTotal[] = dayKeys.map((key) => ({
    dateISO: key,
    total: totalsByDay.get(key) ?? 0,
  }));

  return { days: daysResult, todayTotal: totalsByDay.get(todayKey) ?? 0 };
}
