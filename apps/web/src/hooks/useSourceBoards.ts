import { useLiveQuery } from 'dexie-react-hooks';
import { isEligibleSourceBoard, type Board } from '@oybc/shared';
import { db } from '../db/internal';
import { healBoardNames } from '../db/operations/boardNames';

/**
 * React hook returning the boards eligible to be used as a "source"
 * by the wizard's `From a board…` filter chip — i.e., boards the user
 * can browse and pull tasks from when composing a new board.
 *
 * Eligibility is the shared {@link isEligibleSourceBoard} rule: a board
 * whose window is still open, or one that finished within the last
 * {@link SOURCE_BOARD_LOOKBACK_DAYS} days — whether it finished by being
 * COMPLETED or just by its window closing. Drafts (no real task set yet)
 * and archived boards (intentionally out-of-view) are excluded. Sorted
 * recently-active first (`updatedAt desc`).
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
        const userBoards = healBoardNames(
          await db.boards.filter((b) => b.userId === userId && !b.isDeleted).toArray(),
        );

        // Shared with iOS (`BoardSources.isEligibleSourceBoard`): both
        // ACTIVE and COMPLETED boards are bounded by the same recency
        // window, so a core board whose window closed unfinished — which
        // stays ACTIVE forever — stops being offered once it ages out.
        const now = new Date();
        const eligible = userBoards.filter((b) => isEligibleSourceBoard(b, now));

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
