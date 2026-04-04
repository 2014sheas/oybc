import { useLiveQuery } from 'dexie-react-hooks';
import { db } from '../db/database';
import type { CompositeTask, CompositeNode } from '@oybc/shared';

/**
 * React hook to fetch all non-deleted composite tasks for a user (reactive).
 *
 * @param userId - The user ID to filter by
 * @returns Array of composite tasks, or undefined while loading
 */
export function useCompositeTasks(userId: string | undefined): CompositeTask[] | undefined {
  return useLiveQuery(
    async () => {
      if (!userId) return [];
      const tasks = await db.compositeTasks
        .where('[userId+isDeleted]')
        .equals([userId, 0])
        .sortBy('updatedAt');
      return tasks.reverse();
    },
    [userId],
    undefined
  );
}

/**
 * React hook to fetch all non-deleted nodes for a composite task (reactive).
 *
 * @param compositeTaskId - The composite task ID
 * @returns Array of composite nodes, or undefined while loading
 */
export function useCompositeNodes(compositeTaskId: string | undefined): CompositeNode[] | undefined {
  return useLiveQuery(
    async () => {
      if (!compositeTaskId) return [];
      return db.compositeNodes
        .where('[compositeTaskId+isDeleted]')
        .equals([compositeTaskId, 0])
        .sortBy('nodeIndex');
    },
    [compositeTaskId],
    undefined
  );
}
