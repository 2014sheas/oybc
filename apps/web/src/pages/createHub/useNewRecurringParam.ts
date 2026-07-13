import { useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';

/**
 * "+ New template" deep link: `/create?newRecurring=1` opens the wizard's
 * fresh recurring-board flow (`startRecurring` — `isRecurring` ON at entry,
 * no timeframe lock). Used by Profile → Recurring templates → "+ New
 * template" so the management surface can start a new template (web
 * regained this affordance in the recurring-UX pass; iOS already had it).
 *
 * Watches the URL; when the flag appears, invokes `onConsumed()` once and
 * clears the param so a wizard cancel + manual re-entry doesn't re-arm it.
 *
 * `onConsumed` should be stable (wrapped in `useCallback`).
 */
export function useNewRecurringParam(onConsumed: () => void): void {
  const [searchParams, setSearchParams] = useSearchParams();

  useEffect(() => {
    if (searchParams.get('newRecurring') === null) return;
    onConsumed();
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        next.delete('newRecurring');
        return next;
      },
      { replace: true },
    );
  }, [searchParams, setSearchParams, onConsumed]);
}
