import { useLiveQuery } from 'dexie-react-hooks';
import {
  PARENT_TIMEFRAMES,
  getParentBoards,
  type Task,
  type Timeframe,
} from '@oybc/shared';
import { db } from '../db/internal';

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

        // Match the existing codebase pattern (see useBoards): JS filter
        // rather than the [userId+isDeleted] compound index. The index
        // is declared in db/database.ts but unused everywhere because
        // IndexedDB doesn't support boolean keys natively, making
        // `.equals([userId, false])` unreliable across browsers. The JS
        // filter is consistent + correct; if board count grows enough
        // to make this measurable, switch the schema to `isDeleted: 0|1`
        // and use the index everywhere at once.
        const userBoards = await db.boards
          .filter((b) => b.userId === userId && !b.isDeleted)
          .toArray();

        const parents = getParentBoards(childTimeframe, userBoards, new Date());
        if (parents.length === 0) return [];

        const parentIds = parents.map((b) => b.id);
        // Defensive: `parents` is guaranteed non-empty above, so `parentIds`
        // is too — but guard explicitly so a future refactor that drops
        // the early-return doesn't accidentally pass `[]` to `anyOf`,
        // which has implementation-dependent behavior across IndexedDB
        // backends (some return [], some return all rows).
        if (parentIds.length === 0) return [];
        // Use the boardId index (declared in db/database.ts) so Dexie
        // scans only the relevant board_tasks rows rather than the whole
        // table — important as the user accumulates more boards and
        // placements over time. Mirror of the iOS GRDB perf fix.
        const parentBoardTasks = await db.boardTasks
          .where('boardId')
          .anyOf(parentIds)
          .filter((bt) => !bt.isDeleted)
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
