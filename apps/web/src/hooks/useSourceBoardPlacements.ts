import { useLiveQuery } from 'dexie-react-hooks';
import type { BoardTask, Task } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * One placement on the source board's grid — a `BoardTask` paired
 * with the `Task` it references. The wizard's `From a board` grid
 * needs both: the placement for grid geometry (`row` / `col` /
 * `isCenter`) and the task for type-aware rendering + the context
 * menu.
 *
 * `task` is `undefined` when the placement points at a soft-deleted
 * task — that should be vanishingly rare (cascade delete on the
 * Tasks tab clears `BoardTask` rows) but the grid renders an empty
 * cell rather than crashing if it ever happens.
 */
export interface SourceBoardPlacement {
  placement: BoardTask;
  task: Task | undefined;
}

/**
 * React hook returning placements + resolved tasks for a single source
 * board, ordered by grid position (row-major). Used by the wizard's
 * `From a board` filter to render the source's actual grid.
 *
 * Reactive: recomputes when boardTasks or tasks change. Returns
 * `[]` when `boardId` is undefined.
 */
export function useSourceBoardPlacements(
  boardId: string | undefined
): SourceBoardPlacement[] {
  return (
    useLiveQuery(
      async (): Promise<SourceBoardPlacement[]> => {
        if (!boardId) return [];

        // Use the `boardId` index (declared in db/database.ts) so
        // Dexie scans only the relevant board_tasks rows. Tombstoned
        // placements are excluded (docs/BOARD_INTEGRITY.md).
        const placements = await db.boardTasks
          .where('boardId')
          .equals(boardId)
          .filter((bt) => !bt.isDeleted)
          .toArray();

        if (placements.length === 0) return [];

        const taskIds = Array.from(
          new Set(placements.map((p) => p.taskId))
        );
        const tasks = await db.tasks
          .where('id')
          .anyOf(taskIds)
          .filter((t) => !t.isDeleted)
          .toArray();

        const tasksById = new Map<string, Task>();
        for (const t of tasks) tasksById.set(t.id, t);

        // Row-major ordering so the grid renderer can map placements
        // to cells without needing to sort.
        placements.sort((a, b) =>
          a.row !== b.row ? a.row - b.row : a.col - b.col
        );

        return placements.map((placement) => ({
          placement,
          task: tasksById.get(placement.taskId),
        }));
      },
      [boardId],
      []
    ) ?? []
  );
}
