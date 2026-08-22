import { useCallback, useState } from 'react';
import {
  type Board,
  type Timeframe,
  type UserPreferences,
} from '@oybc/shared';
import { useDrafts } from './createHub/useDrafts';
import { useNewWizardParam } from './createHub/useNewWizardParam';
import { useRecurringTimeframeParam } from './createHub/useRecurringTimeframeParam';
import { useResumableDraft } from './createHub/useResumableDraft';
import { useResumeDraftParam } from './createHub/useResumeDraftParam';
import { useCoreBoardSlots } from '../hooks';
import { deleteDraftWithCascade } from '../db/operations/boards';
import { BoardWizardPage } from './BoardWizardPage';
import { CreateHubBoardCTA } from '../components/createHub/CreateHubBoardCTA';
import { CreateHubDraftsList } from '../components/createHub/CreateHubDraftsList';
import { CoreBoardsSection } from '../components/CoreBoardsSection';
import { RisoSectionLabel } from '../components/riso';
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
      /** Board Creation Split (web PR C) — true when the wizard was
       *  launched from the recurring hub card (or the `?newBoard=recurring`
       *  top-nav deep link). Only takes effect for a truly fresh wizard
       *  (no draft/template/prefill) — see `useBoardWizard`'s hydration
       *  priority. */
      startRecurring?: boolean;
    };

/**
 * CreateHubPage — Landing surface for the Create tab. iOS twin:
 * `CreateHubView`.
 *
 * Composes:
 * - `CreateHubBoardCTA` × 2 (Board Creation Split, web PR C): a RED
 *   one-off card and a BLUE recurring card, each launching the wizard
 *   with its mode fixed at the tap.
 * - `CreateHubDraftsList` (conditional): lists DRAFT boards via the
 *   `useDrafts` hook; tapping a row hydrates the wizard from that
 *   draft.
 *
 * Task library + quick-add moved out of this hub when the dedicated
 * `/tasks` tab landed — Create is now board-creation-only.
 *
 * Deep-link entry points, each handled by a dedicated hook that
 * consumes its param(s) exactly once and clears them from the URL so a
 * wizard cancel + manual re-entry doesn't re-arm anything:
 * `?recurringTimeframe=daily` → `useRecurringTimeframeParam`;
 * `?newBoard=one-off|recurring` → `useNewWizardParam` (the top-nav "New
 * board" button).
 *
 * Board Creation Split (web PR C) reversed the P4 single-CTA merge: the
 * "Repeats" segmented (`useBoardWizard.setRepeats`) that used to decide
 * recurrence mid-wizard is retired — mode is now an entry-time constant
 * threaded as `startRecurring`. P7 retired the second remaining deep
 * link, `?editTemplate=<uuid>[&step=tasks]` (`useEditTemplateParam`),
 * along with the "Recurring templates" Profile page whose Edit/Add-tasks
 * buttons emitted it — repeating-board task edits now happen in place
 * via the Board-settings roster's `RosterEditSheet`, never a wizard
 * round-trip. `BoardWizardPage` / `useBoardWizard` still ACCEPT an
 * `editingTemplate` prop (a generalized "edit an existing repeating
 * board via the wizard" capability with its own tests) — this hub just
 * no longer has any caller that sets it.
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

  // Board Creation Split (web PR C) — mode is fixed at the launch tap;
  // there's no in-wizard "Repeats" toggle to flip it later.
  const handleStartBoard = useCallback((startRecurring: boolean) => {
    setMode({ kind: 'wizard', startRecurring });
  }, []);

  // Top-nav deep link: `/create?newBoard=one-off` (or `=recurring`).
  useNewWizardParam(
    useCallback((startRecurring: boolean) => {
      setMode({ kind: 'wizard', startRecurring });
    }, []),
  );

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
        startRecurring={mode.startRecurring}
        onCancel={returnToHub}
        onComplete={handleWizardComplete}
        onTemplateComplete={handleTemplateComplete}
        onDeleteDraft={(id) => void handleDeleteDraftFromWizard(id)}
      />
    );
  }

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

      {/* Board Creation Split (web PR C) — two mode-locked entry points,
          always shown together at full strength (the old primary/
          secondary demotion driven by `hasUncreatedCoreBoards` is
          retired; only CoreBoardsSection's own presence changes
          prominence now). */}
      <div className={styles.newBoardSection}>
        <RisoSectionLabel>New board</RisoSectionLabel>
        <div className={styles.ctaRow}>
          <CreateHubBoardCTA kind="oneOff" onClick={() => handleStartBoard(false)} />
          <CreateHubBoardCTA kind="recurring" onClick={() => handleStartBoard(true)} />
        </div>
      </div>

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
