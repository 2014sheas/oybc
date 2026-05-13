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
 * Recurring-banner deep link: `/create?recurringTimeframe=daily` opens
 * the wizard immediately with the timeframe prefilled + locked. Watches
 * the URL; when a valid param appears, invokes `onConsumed(timeframe)`
 * once and clears the param so a wizard cancel + manual re-entry doesn't
 * accidentally re-arm the prefill.
 *
 * `onConsumed` should be stable (wrapped in `useCallback`) — it is in
 * the effect's dependency list.
 */
export function useRecurringTimeframeParam(
  onConsumed: (timeframe: Timeframe) => void,
): void {
  const [searchParams, setSearchParams] = useSearchParams();

  useEffect(() => {
    const param = parseRecurringTimeframeParam(
      searchParams.get('recurringTimeframe'),
    );
    if (param === null) return;
    onConsumed(param);
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        next.delete('recurringTimeframe');
        return next;
      },
      { replace: true },
    );
  }, [searchParams, setSearchParams, onConsumed]);
}
