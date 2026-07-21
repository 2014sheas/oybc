import { useLiveQuery } from 'dexie-react-hooks';
import { deriveCounterDailyTotals, SEED_EVENT_OCCURRED_AT } from '@oybc/shared';
import type { CounterDailyTotalsResult } from '@oybc/shared';
import { db } from '../db/internal';
import { currentTimestamp } from '../db/utils';

/** Trailing window size for the Counter Detail sparkline + "Today" stat. */
const SPARKLINE_DAYS = 7;

/** Zero-filled fallback while the live query is still resolving. */
const EMPTY: CounterDailyTotalsResult = { days: [], todayTotal: 0 };

/**
 * Live query hook: a counter's trailing 7-day daily totals + today's total,
 * derived from its source task's raw `task_events` (R2 Counters UX refresh
 * — the Counter Detail sparkline + "Today" stat, fed for REAL; Streak /
 * Best week / Recent weeks stay stubbed pending genuine P4 rollup storage).
 *
 * Reads only `kind:'increment'` events on the counter's source task —
 * linked/derived tasks are carved out and own no events, so there's nothing
 * else to query. Reactively updates whenever a log/undo writes a new event.
 *
 * @param counterId The counter's source task id, or `undefined` while the
 *   route/group hasn't resolved yet.
 * @returns `{ days, todayTotal }` — see `deriveCounterDailyTotals`. `days`
 *   is `[]` while loading (callers should treat an empty array as "no data
 *   yet", not "zero activity every day").
 */
export function useCounterDailyTotals(counterId: string | undefined): CounterDailyTotalsResult {
  return useLiveQuery(
    async () => {
      if (!counterId) return EMPTY;
      const events = await db.taskEvents.where('taskId').equals(counterId).toArray();
      return deriveCounterDailyTotals(events, {
        sourceTaskId: counterId,
        now: currentTimestamp(),
        days: SPARKLINE_DAYS,
        seedSentinel: SEED_EVENT_OCCURRED_AT,
      });
    },
    [counterId],
    EMPTY,
  );
}
