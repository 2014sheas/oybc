import { useLiveQuery } from 'dexie-react-hooks';
import { db } from '../db/database';

/**
 * React hook to fetch board tasks for a board (reactive)
 */
export function useBoardTasks(boardId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!boardId) return [];
      return db.boardTasks.where('boardId').equals(boardId).toArray();
    },
    [boardId],
    []
  );
}

/**
 * React hook to fetch a single board task (reactive)
 */
export function useBoardTask(boardTaskId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!boardTaskId) return undefined;
      return db.boardTasks.get(boardTaskId);
    },
    [boardTaskId]
  );
}

/**
 * React hook to fetch achievement squares
 */
export function useAchievementSquares() {
  return useLiveQuery(
    async () => {
      return db.boardTasks.where('isAchievementSquare').equals(true as any).toArray();
    },
    [],
    []
  );
}
