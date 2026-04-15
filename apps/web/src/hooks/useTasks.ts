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

/**
 * React hook to fetch task steps (reactive)
 */
export function useTaskSteps(taskId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!taskId) return [];

      return db.taskSteps
        .where('[taskId+stepIndex]')
        // Dexie's compound-index range types are under-specified; the
        // tuple shape is correct but the library's typing wants a
        // `readonly unknown[]` here.
        .between([taskId, 0] as readonly unknown[], [taskId, Infinity] as readonly unknown[])
        .filter((s) => !s.isDeleted)
        .toArray();
    },
    [taskId],
    []
  );
}
