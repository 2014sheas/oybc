import type { Board } from '@oybc/shared';
import { fetchBoardTasks } from '../../db/operations/boardTasks';
import { resolveDraftCapacity } from './resolveDraftCapacity';
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
 * resume step. A draft with a mix blob counts from its SOURCES via
 * `resolveDraftCapacity` — the capacity the reopened wizard's Step-2 gate
 * compares, so a board-only draft no longer reopens on Setup (2026-09
 * audit T2). Never `boardTasks.length` for such a draft: the placed rows
 * are a possibly-truncated grid subset of an intentionally overfilled pool
 * (see `Board.recurringDraftMix`'s doc), so counting them would send an
 * already-fillable draft back to the Tasks step.
 */
export function useResumableDraft(): (board: Board) => Promise<ResolvedResumableDraft> {
  // Module-level and stateless, so already referentially stable — no
  // `useCallback` needed.
  return resolveResumableDraft;
}

/**
 * The non-React body of {@link useResumableDraft}: fetch the draft's
 * placements and resolve its resume step. Exported so the resume decision
 * is unit-testable against fake-indexeddb without rendering a hook.
 *
 * @param board - The draft board being resumed.
 * @returns The hydrated draft plus the step the wizard should open on.
 */
export async function resolveResumableDraft(board: Board): Promise<ResolvedResumableDraft> {
  const boardTasks = await fetchBoardTasks(board.id);
  const tasksRequired = tasksNeededFor(board.boardSize as 3 | 4 | 5, board.centerSquareType);
  // Board Sources P1 — one-off drafts saved post-P1 carry the blob too;
  // resolve from it whenever present (same truncation rationale).
  const selectedCount =
    board.isRecurringDraft || board.recurringDraftMix !== undefined
      ? await resolveDraftCapacity(board)
      : boardTasks.length;
  const initialStep = computeDraftInitialStep(tasksRequired, selectedCount);
  return { board, boardTasks, initialStep };
}
