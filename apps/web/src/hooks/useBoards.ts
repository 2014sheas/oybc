import { useLiveQuery } from 'dexie-react-hooks';
import { compareBoardsForList } from '@oybc/shared';
import { db } from '../db/internal';
import { healBoardName, healBoardNames } from '../db/operations/boardNames';

/**
 * React hook to fetch boards for a user (reactive)
 *
 * Automatically updates when boards change in database
 */
export function useBoards(userId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!userId) return [];

      const boards = healBoardNames(
        await db.boards.filter((b) => b.userId === userId && !b.isDeleted).toArray(),
      );
      // Boards-screen ordering: active boards by soonest deadline, then
      // non-active by most recent activity. Shared comparator so web + iOS
      // stay in lock-step (docs: compareBoardsForList).
      return boards.sort((a, b) => compareBoardsForList(a, b));
    },
    [userId],
    [] // Default value while loading
  );
}

/**
 * React hook to fetch a single board (reactive)
 */
export function useBoard(boardId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!boardId) return undefined;
      const board = await db.boards.get(boardId);
      return board ? healBoardName(board) : undefined;
    },
    [boardId]
  );
}
