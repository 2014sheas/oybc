import { useCallback } from 'react';
import type { Board } from '@oybc/shared';
import { fetchBoardTasks } from '../../db/operations/boardTasks';
import { resolveRecurringDraftMixTaskIds } from '../../db/operations/recurringDraftMix';
import { computeDraftInitialStep } from './resolveDraftInitialStep';
import { tasksNeededFor, type BoardWizardDraft, type WizardStep } from './useBoardWizard';

/** `BoardWizardDraft` plus the step the resumed wizard should open on
 *  (Board Creation Split, web PR D — see `computeDraftInitialStep`). */
export interface ResolvedResumableDraft extends BoardWizardDraft {
  initialStep: WizardStep;
}

/**
 * Wraps the "tap a draft → hydrate its placements → hand off to the
 * wizard" flow as a single stable callback. Returns a function that the
 * draft-list onResume handler can invoke directly; the caller is
 * responsible for switching the hub into wizard mode with the resolved
 * draft.
 *
 * Board Creation Split (web PR D) — also resolves the furthest-useful
 * resume step. A recurring draft's true selection count comes from its
 * `recurringDraftMix` (resolved via `resolveRecurringDraftMixTaskIds`),
 * never `boardTasks.length` — the placed rows are a possibly-truncated
 * grid subset of an intentionally overfilled pool (see
 * `Board.recurringDraftMix`'s doc), so counting them would send an
 * already-fillable recurring draft back to the Pool step.
 */
export function useResumableDraft(): (board: Board) => Promise<ResolvedResumableDraft> {
  return useCallback(async (board: Board): Promise<ResolvedResumableDraft> => {
    const boardTasks = await fetchBoardTasks(board.id);
    const tasksRequired = tasksNeededFor(board.boardSize as 3 | 4 | 5, board.centerSquareType);
    // Board Sources P1 — one-off drafts saved post-P1 carry the blob too;
    // resolve from it whenever present (same truncation rationale).
    const selectedCount =
      board.isRecurringDraft || board.recurringDraftMix !== undefined
        ? (await resolveRecurringDraftMixTaskIds(board.recurringDraftMix)).length
        : boardTasks.length;
    const initialStep = computeDraftInitialStep(tasksRequired, selectedCount);
    return { board, boardTasks, initialStep };
  }, []);
}
