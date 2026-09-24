import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { BoardStatus, type Board, type BoardTask } from '@oybc/shared';
import { useBoards, useBoardTasks } from '../../hooks';
import { resolveDraftCapacity } from './resolveDraftCapacity';

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
  const boards = useBoards(userId);
  return useMemo(
    () =>
      (boards ?? [])
        .filter((b) => b.status === BoardStatus.DRAFT && !b.isDeleted)
        // ISO8601 strings sort lexicographically the same way they sort
        // chronologically, so a plain string compare gives the right
        // ordering — most recently updated first.
        .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)),
    [boards],
  );
}

/**
 * Reactive task count for a single draft board. Intended for the
 * drafts-list rows so each row can show "X of Y tasks" without the
 * hub having to fetch every BoardTask upfront.
 *
 * A draft carrying a mix blob counts from its SOURCES — the wizard's own
 * capacity number (`resolveDraftCapacity`), so a board-kind source or a
 * capped range counts exactly as the reopened wizard will show it (2026-09
 * audit T2; the old pool-mix read counted a board-only draft as 0). The
 * placed `BoardTask` rows would truncate an intentionally overfilled pool
 * (see `Board.recurringDraftMix`'s doc), so they only count for a legacy
 * blob-less one-off draft. Both hooks are called unconditionally (rule of
 * hooks); the branch below picks the result.
 */
export function useDraftTaskCount(board: Board): number {
  const boardTasks: BoardTask[] = useBoardTasks(board.id) ?? [];
  const hasMixBlob = board.isRecurringDraft || board.recurringDraftMix !== undefined;
  const capacity = useLiveQuery(
    async () => (hasMixBlob ? resolveDraftCapacity(board) : 0),
    [hasMixBlob, board.recurringDraftMix, board.centerSquareType, board.centerTaskId],
  );
  if (hasMixBlob) return capacity ?? 0;
  return boardTasks.length;
}
