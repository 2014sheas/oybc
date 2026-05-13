import { useLiveQuery } from 'dexie-react-hooks';
import type { RecurringBoardTemplate } from '@oybc/shared';
import { db } from '../db/database';

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
