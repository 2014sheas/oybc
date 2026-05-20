import { useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Timeframe } from '@oybc/shared';

/**
 * Parse the `recurringTimeframe` URL search param into a valid Timeframe
 * (excluding CUSTOM, which Phase 1 doesn't support). Returns null when
 * absent, malformed, or CUSTOM. Defensive — a hand-typed URL shouldn't
 * crash the wizard.
 */
function parseRecurringTimeframeParam(value: string | null): Timeframe | null {
  switch (value) {
    case Timeframe.DAILY:
    case Timeframe.WEEKLY:
    case Timeframe.MONTHLY:
    case Timeframe.YEARLY:
      return value;
    default:
      return null;
  }
}

/**
 * Parse a `YYYY-MM-DD` window-target string from the URL into a local
 * `Date` at start-of-day. Used by the core-board browser to spawn a
 * specific window's board (e.g. tomorrow's daily) via the wizard.
 * Returns null when absent or malformed — the wizard then falls back
 * to today's window (the historic banner behaviour).
 *
 * Parses manually (not via `new Date('YYYY-MM-DD')`) to avoid the
 * silent UTC coercion that would shift the window for users east of
 * UTC — same defensive pattern `wizardPersist.ts` uses for custom
 * date inputs.
 */
function parseWindowDateParam(value: string | null): Date | null {
  if (value === null) return null;
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return null;
  const [, y, m, d] = match;
  const date = new Date(Number(y), Number(m) - 1, Number(d), 0, 0, 0, 0);
  if (Number.isNaN(date.getTime())) return null;
  return date;
}

/**
 * Recurring-banner deep link: `/create?recurringTimeframe=daily` opens
 * the wizard immediately with the timeframe prefilled + locked. Watches
 * the URL; when a valid param appears, invokes `onConsumed(timeframe, windowDate?)`
 * once and clears both params so a wizard cancel + manual re-entry doesn't
 * accidentally re-arm the prefill.
 *
 * The optional `?windowDate=YYYY-MM-DD` second param is set by the
 * core-board browser when spawning a non-current window (Phase B). When
 * present, it's forwarded as a `Date` so the wizard's target window
 * matches the user's pick instead of always being "today". Without it,
 * `windowDate` is `undefined` and the wizard defaults to today's window.
 *
 * `onConsumed` should be stable (wrapped in `useCallback`) — it is in
 * the effect's dependency list.
 */
export function useRecurringTimeframeParam(
  onConsumed: (timeframe: Timeframe, windowDate?: Date) => void,
): void {
  const [searchParams, setSearchParams] = useSearchParams();

  useEffect(() => {
    const param = parseRecurringTimeframeParam(
      searchParams.get('recurringTimeframe'),
    );
    if (param === null) return;
    const windowDate = parseWindowDateParam(searchParams.get('windowDate'));
    onConsumed(param, windowDate ?? undefined);
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        next.delete('recurringTimeframe');
        next.delete('windowDate');
        return next;
      },
      { replace: true },
    );
  }, [searchParams, setSearchParams, onConsumed]);
}
