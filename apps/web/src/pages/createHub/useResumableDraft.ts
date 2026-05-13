import { useCallback } from 'react';
import type { Board } from '@oybc/shared';
import { fetchBoardTasks } from '../../db/operations/boardTasks';
import type { BoardWizardDraft } from './useBoardWizard';

/**
 * Wraps the "tap a draft → hydrate its placements → hand off to the
 * wizard" flow as a single stable callback. Returns a function that the
 * draft-list onResume handler can invoke directly; the caller is
 * responsible for switching the hub into wizard mode with the resolved
 * draft.
 */
export function useResumableDraft(): (board: Board) => Promise<BoardWizardDraft> {
  return useCallback(async (board: Board): Promise<BoardWizardDraft> => {
    const boardTasks = await fetchBoardTasks(board.id);
    return { board, boardTasks };
  }, []);
}
