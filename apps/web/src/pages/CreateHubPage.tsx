import { useCallback, useState } from 'react';
import {
  type Board,
  type Timeframe,
  type UserPreferences,
} from '@oybc/shared';
import { useDrafts } from './createHub/useDrafts';
import { useRecurringTimeframeParam } from './createHub/useRecurringTimeframeParam';
import { useResumableDraft } from './createHub/useResumableDraft';
import { useResumeDraftParam } from './createHub/useResumeDraftParam';
import { useCoreBoardSlots } from '../hooks';
import { deleteDraftWithCascade } from '../db/operations/boards';
import { BoardWizardPage } from './BoardWizardPage';
import { CreateHubBoardCTA } from '../components/createHub/CreateHubBoardCTA';
import { CreateHubDraftsList } from '../components/createHub/CreateHubDraftsList';
import { CoreBoardsSection } from '../components/CoreBoardsSection';
import type { BoardWizardDraft } from './createHub/useBoardWizard';
import styles from './CreateHubPage.module.css';

export interface CreateHubPageProps {
  userId: string;
  preferences: UserPreferences;
  /** Called after a board is successfully activated or saved as a
   *  draft. Parent typically navigates to the created board
   *  (`/boards/:id`) or lets the hub re-render with the updated
   *  drafts list. */
  onBoardCompleted?: (boardId: string, status: 'active' | 'draft') => void;
  /** Phase 6.2: called when a recurring template was saved without a
   *  spawnable board (skip or edit). Parent should navigate to the
   *  Board-settings page (`/profile/board-settings`) rather than
   *  `/boards/${id}`. */
  onTemplateCompleted?: (templateId: string) => void;
}

type HubMode =
  | { kind: 'hub' }
  | {
      kind: 'wizard';
      draft?: BoardWizardDraft;
      /** Set when the wizard was launched from the Boards-tab Recurring
       *  Boards banner (`/create?recurringTimeframe=daily`). The setup
       *  step locks the timeframe field to this value. */
      prefilledRecurringTimeframe?: Timeframe;
      /** Set when the wizard was launched from the core-board browser
       *  to spawn a non-current window (`/create?recurringTimeframe=daily&windowDate=2026-05-25`).
       *  Threaded as a `Date` into the wizard so `resolveWizardDates`
       *  picks the right window. Always paired with `prefilledRecurringTimeframe`. */
      targetWindowDate?: Date;
    };

/**
 * CreateHubPage — Landing surface for the Create tab. iOS twin:
 * `CreateHubView`.
 *
 * Composes:
 * - `CreateHubBoardCTA`: primary "Start a new board" action that
 *   swaps the view into the 3-step wizard.
 * - `CreateHubDraftsList` (conditional): lists DRAFT boards via the
 *   `useDrafts` hook; tapping a row hydrates the wizard from that
 *   draft.
 *
 * Task library + quick-add moved out of this hub when the dedicated
 * `/tasks` tab landed — Create is now board-creation-only.
 *
 * One deep-link entry point remains, handled by a dedicated hook:
 * `?recurringTimeframe=daily` → `useRecurringTimeframeParam`. It consumes
 * its param(s) exactly once and clears them from the URL so a wizard
 * cancel + manual re-entry doesn't re-arm the prefill.
 *
 * P4 (Task Pools + Recurring Boards Rework) retired the separate
 * "Create a recurring board" CTA + its `?newRecurring=1` deep link —
 * there's now ONE "Start a new board" CTA; recurrence is chosen via the
 * wizard's Step 1 "Repeats" segmented (`useBoardWizard.setRepeats`). P7
 * retired the second remaining deep link, `?editTemplate=<uuid>[&step=tasks]`
 * (`useEditTemplateParam`), along with the "Recurring templates" Profile
 * page whose Edit/Add-tasks buttons emitted it — repeating-board task
 * edits now happen in place via the Board-settings roster's
 * `RosterEditSheet`, never a wizard round-trip. `BoardWizardPage` /
 * `useBoardWizard` still ACCEPT an `editingTemplate` prop (a generalized
 * "edit an existing repeating board via the wizard" capability with its
 * own tests) — this hub just no longer has any caller that sets it.
 */
export function CreateHubPage({
  userId,
  preferences,
  onBoardCompleted,
  onTemplateCompleted,
}: CreateHubPageProps): React.ReactElement {
  const [mode, setMode] = useState<HubMode>({ kind: 'hub' });
  const drafts = useDrafts(userId);
  const coreBoardSlots = useCoreBoardSlots(userId);
  const resolveDraft = useResumableDraft();

  useRecurringTimeframeParam(
    useCallback((timeframe: Timeframe, windowDate?: Date) => {
      setMode({
        kind: 'wizard',
        prefilledRecurringTimeframe: timeframe,
        targetWindowDate: windowDate,
      });
    }, []),
  );

  const returnToHub = useCallback(() => setMode({ kind: 'hub' }), []);

  const handleStartBoard = useCallback(() => {
    setMode({ kind: 'wizard' });
  }, []);

  const handleResumeDraft = useCallback(
    async (board: Board): Promise<void> => {
      const draft = await resolveDraft(board);
      setMode({ kind: 'wizard', draft });
    },
    [resolveDraft],
  );

  // Cross-tab draft-resume bridge: `/create?resumeDraft=<boardId>` (set by
  // the Boards tab when the user taps a DRAFT card or a draft CoreStrip slot,
  // the CoreBoardBrowser row, and by the BoardPlayPage catch-all guard).
  // Reuses `handleResumeDraft` — the same path the CreateHub drafts list uses
  // — so there's exactly one resume path. Handles not-found / non-draft boards
  // gracefully (no callback fired).
  useResumeDraftParam(
    useCallback((board) => {
      void handleResumeDraft(board);
    }, [handleResumeDraft]),
  );

  const handleDeleteDraft = useCallback(async (board: Board): Promise<void> => {
    await deleteDraftWithCascade(board.id);
  }, []);

  // Wizard-cancel-dialog "Delete draft" path: delete the draft AND
  // close the wizard back to the hub. The drafts-list `useLiveQuery`
  // refreshes automatically. Separate from `handleDeleteDraft` (which
  // is the per-row × button — no wizard-close side effect).
  const handleDeleteDraftFromWizard = useCallback(
    async (boardId: string): Promise<void> => {
      await deleteDraftWithCascade(boardId);
      returnToHub();
    },
    [returnToHub],
  );

  const handleWizardComplete = useCallback(
    (boardId: string, status: 'active' | 'draft'): void => {
      onBoardCompleted?.(boardId, status);
      returnToHub();
    },
    [onBoardCompleted, returnToHub],
  );

  // Phase 6.2: recurring-template-only completions (spawn skip OR
  // edit) — the parent navigates to the Profile templates list. We
  // still `returnToHub` first so the in-place transition resets, but
  // the App-level handler then re-routes off this page entirely.
  const handleTemplateComplete = useCallback(
    (templateId: string): void => {
      onTemplateCompleted?.(templateId);
      returnToHub();
    },
    [onTemplateCompleted, returnToHub],
  );

  if (mode.kind === 'wizard') {
    return (
      <BoardWizardPage
        userId={userId}
        preferences={preferences}
        draft={mode.draft}
        prefilledRecurringTimeframe={mode.prefilledRecurringTimeframe}
        targetWindowDate={mode.targetWindowDate}
        onCancel={returnToHub}
        onComplete={handleWizardComplete}
        onTemplateComplete={handleTemplateComplete}
        onDeleteDraft={(id) => void handleDeleteDraftFromWizard(id)}
      />
    );
  }

  // Demote the custom-board CTA to "secondary" only when at least one
  // core-board slot needs creation today — the persistent Core Boards
  // section is the headline action in that case. When every enabled
  // slot is already done (or none are enabled), the custom CTA stays
  // primary so the user has an obvious next action.
  const hasUncreatedCoreBoards = coreBoardSlots.some(
    (s) => s.currentBoard === null,
  );

  return (
    <div className={styles.shell}>
      <header className={styles.header}>
        <h1 className={styles.title}>Create</h1>
      </header>

      <CoreBoardsSection
        slots={coreBoardSlots}
        // Already on /create — whole-row tap launches the wizard for
        // that timeframe's current window in place, no cross-tab hop.
        // Same end state as the Boards-tab caller's "tap row → browser
        // → tap current cell → wizard", just one step shorter for the
        // common "I'm here to create" intent. To browse past/future
        // windows the user goes to the Boards tab.
        onSelect={(slot) =>
          setMode({ kind: 'wizard', prefilledRecurringTimeframe: slot.timeframe })
        }
      />

      <CreateHubBoardCTA
        onClick={handleStartBoard}
        variant={hasUncreatedCoreBoards ? 'secondary' : 'primary'}
      />

      {drafts.length > 0 && (
        <CreateHubDraftsList
          drafts={drafts}
          onResume={(d) => void handleResumeDraft(d)}
          onDelete={(d) => void handleDeleteDraft(d)}
        />
      )}
    </div>
  );
}
