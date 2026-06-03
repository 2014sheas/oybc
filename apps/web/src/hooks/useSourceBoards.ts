import { useLiveQuery } from 'dexie-react-hooks';
import { BoardStatus, type Board } from '@oybc/shared';
import { db } from '../db/database';

/** Boards completed more recently than this stay eligible as a source. */
const COMPLETED_LOOKBACK_DAYS = 30;

/**
 * React hook returning the boards eligible to be used as a "source"
 * by the wizard's `From a board…` filter chip — i.e., boards the user
 * can browse and pull tasks from when composing a new board.
 *
 * Eligibility:
 *   - `userId === userId` and `!isDeleted` (standard owner filter)
 *   - `status === ACTIVE`, OR
 *   - `status === COMPLETED` and `completedAt` within the last
 *     {@link COMPLETED_LOOKBACK_DAYS} days
 *
 * Drafts (no real task set yet) and archived boards (intentionally
 * out-of-view) are excluded. Sorted recently-active first
 * (`updatedAt desc`).
 *
 * Reactive: recomputes when boards change.
 */
export function useSourceBoards(userId: string | undefined): Board[] {
  return (
    useLiveQuery(
      async (): Promise<Board[]> => {
        if (!userId) return [];

        // Match the existing codebase pattern (see useBoards /
        // useParentBoardTasks): JS filter rather than the
        // [userId+isDeleted] compound index. The index is declared but
        // unused everywhere because IndexedDB's boolean-key handling
        // is unreliable across browsers.
        const userBoards = await db.boards
          .filter((b) => b.userId === userId && !b.isDeleted)
          .toArray();

        const cutoff = Date.now() - COMPLETED_LOOKBACK_DAYS * 24 * 60 * 60 * 1000;
        const eligible = userBoards.filter((b) => {
          if (b.status === BoardStatus.ACTIVE) return true;
          if (b.status !== BoardStatus.COMPLETED) return false;
          if (!b.completedAt) return false;
          const ts = Date.parse(b.completedAt);
          if (Number.isNaN(ts)) return false;
          return ts >= cutoff;
        });

        // ISO8601 strings compare correctly with localeCompare. Negated
        // for descending order; ties intentionally return 0 so Array.sort
        // preserves the input order (stable in V8 / modern engines).
        eligible.sort((a, b) => -a.updatedAt.localeCompare(b.updatedAt));
        return eligible;
      },
      [userId],
      []
    ) ?? []
  );
}
