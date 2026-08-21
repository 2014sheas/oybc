import { useLiveQuery } from 'dexie-react-hooks';
import { db } from '../db/internal';

/**
 * React hook to fetch non-deleted board tasks for a board (reactive)
 */
export function useBoardTasks(boardId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!boardId) return [];
      return db.boardTasks.where('boardId').equals(boardId).filter((bt) => !bt.isDeleted).toArray();
    },
    [boardId],
    []
  );
}

