import { useLiveQuery } from 'dexie-react-hooks';
import type { RecurringBoardTemplate } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * React hook returning the user's non-deleted recurring board templates,
 * sorted by `updatedAt desc` (most-recently-edited first). Reactive:
 * rebuilds whenever the templates table changes.
 *
 * Returns `[]` while loading or when the user is signed out.
 */
export function useRecurringBoardTemplates(
  userId: string | undefined,
): RecurringBoardTemplate[] {
  return (
    useLiveQuery(
      async (): Promise<RecurringBoardTemplate[]> => {
        if (!userId) return [];
        // Match the codebase pattern (see `useBoards`): JS filter rather
        // than the [userId+isDeleted] compound index. IndexedDB doesn't
        // support boolean keys natively, so the index would be unreliable
        // across browsers.
        return db.recurringBoardTemplates
          .filter((t) => t.userId === userId && !t.isDeleted)
          .reverse()
          .sortBy('updatedAt');
      },
      [userId],
      [],
    ) ?? []
  );
}

/**
 * Tri-state variant of {@link useRecurringBoardTemplates}: `undefined`
 * until the first resolve, so callers can tell "no templates" from "not
 * read yet".
 *
 * Late-mutation audit (2026-09-16, shape B): collapsing the loading
 * state to `[]` made a spawned board's badge render un-paused (and the
 * card un-dimmed, with no cadence subtitle) and then flip to "↻ PAUSED"
 * once the query landed. Callers rendering COPY/BADGES about a
 * template should use this. See `reference_late_mutation_bug_class`.
 */
export function useRecurringBoardTemplatesQuery(
  userId: string | undefined,
): RecurringBoardTemplate[] | undefined {
  return useLiveQuery(
    async (): Promise<RecurringBoardTemplate[]> => {
      if (!userId) return [];
      return db.recurringBoardTemplates
        .filter((t) => t.userId === userId && !t.isDeleted)
        .toArray();
    },
    [userId],
  );
}
