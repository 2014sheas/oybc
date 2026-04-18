import { useMemo } from 'react';
import { BoardStatus, type Board, type BoardTask } from '@oybc/shared';
import { useBoards, useBoardTasks } from '../../hooks';

export interface DraftWithTaskCount {
  board: Board;
  taskCount: number;
}

/**
 * Reactive list of DRAFT boards for the given user, most recently
 * updated first. Dexie's `useLiveQuery` ensures the list refreshes
 * automatically when the wizard saves or activates a draft.
 */
export function useDrafts(userId: string | undefined): Board[] {
  const boards = useBoards(userId) ?? [];
  return useMemo(
    () => boards.filter((b) => b.status === BoardStatus.DRAFT && !b.isDeleted),
    [boards],
  );
}

/**
 * Reactive task count for a single draft board. Intended for the
 * drafts-list rows so each row can show "X of Y tasks" without the
 * hub having to fetch every BoardTask upfront.
 */
export function useDraftTaskCount(boardId: string): number {
  const tasks: BoardTask[] = useBoardTasks(boardId) ?? [];
  return tasks.length;
}
