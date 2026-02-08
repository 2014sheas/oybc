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
        .where('[userId+isDeleted]')
        .equals([userId, false] as any)
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

/**
 * React hook to fetch task steps (reactive)
 */
export function useTaskSteps(taskId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!taskId) return [];

      return db.taskSteps
        .where('[taskId+stepIndex]')
        .between([taskId, 0] as any, [taskId, Infinity] as any)
        .filter((s) => !s.isDeleted)
        .toArray();
    },
    [taskId],
    []
  );
}
