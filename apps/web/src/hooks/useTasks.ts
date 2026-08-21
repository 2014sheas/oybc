import { useLiveQuery } from 'dexie-react-hooks';
import { db } from '../db/internal';

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
