import { useMemo } from 'react';
import { BoardStatus, type Board, type BoardTask } from '@oybc/shared';
import { useBoards, useBoardTasks, useRecurringDraftMix } from '../../hooks';

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
 * Board Creation Split (web PR D) — a recurring draft's true pool size
 * lives in `recurringDraftMix`, not the placed `BoardTask` rows (which
 * truncate an intentionally overfilled pool to the grid size — see
 * `Board.recurringDraftMix`'s doc). Both hooks are called unconditionally
 * (rule of hooks); only the branch below decides which result to use, so
 * a one-off draft never pays for the (short-circuited, empty) mix
 * resolution and vice versa.
 */
export function useDraftTaskCount(board: Board): number {
  const boardTasks: BoardTask[] = useBoardTasks(board.id) ?? [];
  // Board Sources P1 — one-off drafts saved post-P1 carry the blob too;
  // count from it whenever present (same truncation rationale). Legacy
  // blob-less one-off drafts keep the boardTasks count.
  const hasMixBlob = board.isRecurringDraft || board.recurringDraftMix !== undefined;
  const recurringMix = useRecurringDraftMix(
    hasMixBlob ? board.recurringDraftMix : undefined,
  );
  if (hasMixBlob) return recurringMix?.size ?? 0;
  return boardTasks.length;
}
