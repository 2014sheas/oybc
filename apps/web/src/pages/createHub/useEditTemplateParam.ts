import { useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import type { RecurringBoardTemplate } from '@oybc/shared';
import { fetchRecurringBoardTemplate } from '../../db/operations/recurringBoardTemplates';

/**
 * Profile → Recurring templates → Edit / Add-tasks deep link:
 * `/create?editTemplate=<uuid>` opens the wizard hydrated from the
 * template, in template-edit mode. An optional `&step=tasks` lands the
 * wizard directly on the Tasks step (2) — used by the row's "Add tasks"
 * affordance so adding a task doesn't force the user back through the
 * whole setup step. Watches the URL; when a valid id appears, fetches
 * the template, invokes `onConsumed(template, initialStep)` if it
 * resolved, then clears both params so a wizard cancel + manual
 * re-entry doesn't re-arm the edit.
 *
 * A concurrently-deleted template surfaces as no callback fire (the
 * fetch returns undefined). The URL is cleared in both branches so the
 * state machine doesn't get stuck.
 *
 * `onConsumed` should be stable (wrapped in `useCallback`).
 */
export function useEditTemplateParam(
  onConsumed: (template: RecurringBoardTemplate, initialStep: 1 | 2) => void,
): void {
  const [searchParams, setSearchParams] = useSearchParams();

  useEffect(() => {
    const id = searchParams.get('editTemplate');
    if (id === null) return;
    // `step=tasks` → land on the Tasks step (2). Anything else → Setup (1).
    const initialStep: 1 | 2 =
      searchParams.get('step') === 'tasks' ? 2 : 1;
    let cancelled = false;
    void (async () => {
      const template = await fetchRecurringBoardTemplate(id);
      if (cancelled) return;
      if (template !== undefined) {
        onConsumed(template, initialStep);
      }
      setSearchParams(
        (prev) => {
          const next = new URLSearchParams(prev);
          next.delete('editTemplate');
          next.delete('step');
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
