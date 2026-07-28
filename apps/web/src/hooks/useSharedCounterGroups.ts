import { useLiveQuery } from 'dexie-react-hooks';
import { buildSharedCounterGroups } from '@oybc/shared';
import type { SharedCounterGroup } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * Live query hook: builds the SharedCounterGroup read-model for the
 * authenticated user's task graph. Reactively updates whenever tasks,
 * boards, or board-task placements change in Dexie.
 *
 * Uses `buildSharedCounterGroups` from `@oybc/shared` — the pure read
 * model over the existing shared-counter engine (Issue #84, Phases 0–4).
 * No new stored state is introduced; this is a view over live DB rows.
 *
 * @param userId - The authenticated user's id. Returns [] when undefined.
 * @returns Stable-sorted (by name) array of SharedCounterGroup view-models.
 *   Empty while loading, empty when the user has no shared counters.
 */
export function useSharedCounterGroups(userId: string | undefined): SharedCounterGroup[] {
  return useLiveQuery(
    async () => {
      if (!userId) return [];

      // Fetch all non-deleted tasks + boards for this user. `buildSharedCounterGroups`
      // also filters isDeleted internally, but pre-filtering avoids pulling tombstones
      // through the grouping logic unnecessarily.
      const [tasks, boards] = await Promise.all([
        db.tasks.filter((t) => t.userId === userId && !t.isDeleted).toArray(),
        db.boards.filter((b) => b.userId === userId && !b.isDeleted).toArray(),
      ]);

      // Pull all boardTasks that link to any of the user's tasks, using the `taskId`
      // index from schema v7 (`anyOf` keeps this to one indexed range scan per chunk).
      const taskIds = tasks.map((t) => t.id);
      const boardTasks =
        taskIds.length > 0
          ? await db.boardTasks.where('taskId').anyOf(taskIds).filter((bt) => !bt.isDeleted).toArray()
          : [];

      return buildSharedCounterGroups({ tasks, boardTasks, boards });
    },
    [userId],
    [] // default while loading
  );
}
