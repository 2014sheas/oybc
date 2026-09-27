import { useLiveQuery } from 'dexie-react-hooks';
import type { BoardTask } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * React hook to fetch non-deleted board tasks for a board (reactive).
 * Returns `[]` while loading — use `useBoardTasksQuery` when "loading"
 * must be told apart from "this board has no placements".
 */
export function useBoardTasks(boardId: string | undefined) {
  return useLiveQuery(
    async () => {
      if (!boardId) return [];
      return db.boardTasks.where('boardId').equals(boardId).filter((bt) => !bt.isDeleted).toArray();
    },
    [boardId],
    []
  );
}

/**
 * Tri-state twin of `useBoardTasks`: `undefined` while the live query is
 * unresolved, `[]` once a board is known to have zero placements. The play
 * surface gates its "Loading…" on this so an emptied board still renders.
 *
 * @param boardId - The board whose non-deleted placements to read.
 * @returns The placements, or `undefined` while loading.
 */
export function useBoardTasksQuery(boardId: string | undefined): BoardTask[] | undefined {
  return useLiveQuery(
    async (): Promise<BoardTask[]> => {
      if (!boardId) return [];
      return db.boardTasks.where('boardId').equals(boardId).filter((bt) => !bt.isDeleted).toArray();
    },
    [boardId],
  );
}
