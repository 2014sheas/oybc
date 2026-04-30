import { useLiveQuery } from 'dexie-react-hooks';
import { db } from '../db/database';

/**
 * React hook to fetch tasks for a user (reactive)
 */
export function useTasks(userId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!userId) return [];

      return db.tasks
        .filter((t) => t.userId === userId && !t.isDeleted)
        .sortBy('title');
    },
    [userId],
    []
  );
}

/**
 * React hook to fetch a single task (reactive)
 */
export function useTask(taskId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!taskId) return undefined;
      return db.tasks.get(taskId);
    },
    [taskId]
  );
}
