import { useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import type { RecurringBoardTemplate } from '@oybc/shared';
import { fetchRecurringBoardTemplate } from '../../db/operations/recurringBoardTemplates';

/**
 * Profile → Recurring templates → Edit deep link:
 * `/create?editTemplate=<uuid>` opens the wizard hydrated from the
 * template, in template-edit mode. Watches the URL; when a valid id
 * appears, fetches the template, invokes `onConsumed(template)` if it
 * resolved, then clears the param so a wizard cancel + manual re-entry
 * doesn't re-arm the edit.
 *
 * A concurrently-deleted template surfaces as no callback fire (the
 * fetch returns undefined). The URL is cleared in both branches so the
 * state machine doesn't get stuck.
 *
 * `onConsumed` should be stable (wrapped in `useCallback`).
 */
export function useEditTemplateParam(
  onConsumed: (template: RecurringBoardTemplate) => void,
): void {
  const [searchParams, setSearchParams] = useSearchParams();

  useEffect(() => {
    const id = searchParams.get('editTemplate');
    if (id === null) return;
    let cancelled = false;
    void (async () => {
      const template = await fetchRecurringBoardTemplate(id);
      if (cancelled) return;
      if (template !== undefined) {
        onConsumed(template);
      }
      setSearchParams(
        (prev) => {
          const next = new URLSearchParams(prev);
          next.delete('editTemplate');
          return next;
        },
        { replace: true },
      );
    })();
    return () => {
      cancelled = true;
    };
  }, [searchParams, setSearchParams, onConsumed]);
}
