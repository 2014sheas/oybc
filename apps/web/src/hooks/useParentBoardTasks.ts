import { useLiveQuery } from 'dexie-react-hooks';
import {
  PARENT_TIMEFRAMES,
  getParentBoards,
  type Task,
  type Timeframe,
} from '@oybc/shared';
import { db } from '../db/database';

/**
 * React hook returning the unique tasks placed on currently-active "parent"
 * boards for a given child timeframe. Used by the wizard's "From parent
 * boards" filter chip — selecting a task surfaced here places it on the
 * new (child) board via the standard placement path, with the same `taskId`.
 * Per Phase 6.1's locked design, completion is shared globally (no clone).
 *
 * Returns `[]` when:
 *   - signed out
 *   - the child timeframe has no parents (yearly, custom)
 *   - no parent boards are currently active (common on first open with
 *     prefs newly enabled — banner-driven flow surfaces parents in
 *     longest-first order to mitigate)
 *
 * Reactive: recomputes when boards, board_tasks, or tasks change.
 */
export function useParentBoardTasks(
  userId: string | undefined,
  childTimeframe: Timeframe
): Task[] {
  return (
    useLiveQuery(
      async (): Promise<Task[]> => {
        if (!userId) return [];
        if (PARENT_TIMEFRAMES[childTimeframe].length === 0) return [];

        const userBoards = await db.boards
          .filter((b) => b.userId === userId && !b.isDeleted)
          .toArray();

        const parents = getParentBoards(childTimeframe, userBoards, new Date());
        if (parents.length === 0) return [];

        const parentIds = new Set(parents.map((b) => b.id));
        const parentBoardTasks = await db.boardTasks
          .filter((bt) => parentIds.has(bt.boardId))
          .toArray();

        const taskIds = Array.from(
          new Set(parentBoardTasks.map((bt) => bt.taskId))
        );
        if (taskIds.length === 0) return [];

        const tasks = await db.tasks
          .where('id')
          .anyOf(taskIds)
          .filter((t) => !t.isDeleted)
          .toArray();

        // Stable ordering for predictable UI — alphabetical by title.
        return tasks.sort((a, b) => a.title.localeCompare(b.title));
      },
      [userId, childTimeframe],
      []
    ) ?? []
  );
}
