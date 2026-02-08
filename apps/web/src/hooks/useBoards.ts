import { useLiveQuery } from 'dexie-react-hooks';
import { db } from '../db/database';

/**
 * React hook to fetch boards for a user (reactive)
 *
 * Automatically updates when boards change in database
 */
export function useBoards(userId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!userId) return [];

      return db.boards
        .where('[userId+isDeleted]')
        .equals([userId, false] as any)
        .reverse()
        .sortBy('updatedAt');
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
      return db.boards.get(boardId);
    },
    [boardId]
  );
}

/**
 * React hook to fetch boards with bingos by timeframe
 */
export function useBoardsWithBingos(userId: string | undefined, timeframe: string) {
  return useLiveQuery(
    async () => {
      if (!userId) return [];

      return db.boards
        .where('[userId+timeframe+linesCompleted]')
        .between([userId, timeframe, 1] as any, [userId, timeframe, Infinity] as any)
        .toArray();
    },
    [userId, timeframe],
    []
  );
}
