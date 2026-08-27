import { useCallback, useState } from 'react';
import {
  BoardStatus,
  canCreateBoard,
  isFeatureGated,
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
import { useBoards } from '../hooks/useBoards';
import { useEntitlement } from '../hooks/useEntitlement';
import { ProPaywall } from '../components/paywall/ProPaywall';
import { deleteDraftWithCascade } from '../db/operations/boards';
import { BoardWizardPage } from './BoardWizardPage';
import { CreateHubBoardCTA } from '../components/createHub/CreateHubBoardCTA';
import { CreateHubDraftsList } from '../components/createHub/CreateHubDraftsList';
import { CoreBoardsSection } from '../components/CoreBoardsSection';
import { RisoSectionLabel } from '../components/riso';
import type { BoardWizardDraft, WizardStep } from './createHub/useBoardWizard';
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
      /** Board Creation Split (web PR D) — the furthest useful step a
       *  resumed draft should open on (`resolveDraftInitialStep`).
       *  Undefined for every non-draft entry point (defaults to Setup). */
      initialStep?: WizardStep;
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
 * buttons emitted it. Board Creation Split (web PR D) went further and
 * retired the Board-settings roster's local `RosterEditSheet` too —
 * "Edit tasks" now opens `BoardWizardPage` itself in edit mode
 * (`RepeatingBoardWizardOverlay`, `editingTemplate` set), so this hub's
 * own `editingTemplate` support (still accepted here, just with no
 * caller in THIS file) is the same code path both surfaces share.
 */
export function CreateHubPage({
  userId,
  preferences,
  onBoardCompleted,
  onTemplateCompleted,
}: CreateHubPageProps): React.ReactElement {
  const [mode, setMode] = useState<HubMode>({ kind: 'hub' });
  const [showPaywall, setShowPaywall] = useState(false);
  const { entitlement } = useEntitlement();
  const boards = useBoards(userId);
  const activeBoardCount = boards.filter(
    (b) => b.status === BoardStatus.ACTIVE && !b.sealedAt,
  ).length;

  // Pro gate for any recurring/core board entry (docs/MONETIZATION.md). Opens
  // the paywall and returns false when a free user tries a recurring board.
  const ensureRecurringAllowed = useCallback((): boolean => {
    if (isFeatureGated('recurring-boards', entitlement, Date.now())) {
      setShowPaywall(true);
      return false;
    }
    return true;
  }, [entitlement]);
  const drafts = useDrafts(userId);
  const coreBoardSlots = useCoreBoardSlots(userId);
  const resolveDraft = useResumableDraft();

  useRecurringTimeframeParam(
    useCallback(
      (timeframe: Timeframe, windowDate?: Date) => {
        if (!ensureRecurringAllowed()) return;
        setMode({
          kind: 'wizard',
          prefilledRecurringTimeframe: timeframe,
          targetWindowDate: windowDate,
        });
      },
      [ensureRecurringAllowed],
    ),
  );

  const returnToHub = useCallback(() => setMode({ kind: 'hub' }), []);

  // Board Creation Split (web PR C) — mode is fixed at the launch tap;
  // there's no in-wizard "Repeats" toggle to flip it later.
  const handleStartBoard = useCallback(
    (startRecurring: boolean) => {
      if (startRecurring) {
        if (!ensureRecurringAllowed()) return;
      } else if (!canCreateBoard(activeBoardCount, entitlement, Date.now())) {
        setShowPaywall(true);
        return;
      }
      setMode({ kind: 'wizard', startRecurring });
    },
    [ensureRecurringAllowed, activeBoardCount, entitlement],
  );

  // Top-nav deep link: `/create?newBoard=one-off` (or `=recurring`).
  useNewWizardParam(
    useCallback((startRecurring: boolean) => {
      handleStartBoard(startRecurring);
    }, [handleStartBoard]),
  );

  const handleResumeDraft = useCallback(
    async (board: Board): Promise<void> => {
      const { board: resolvedBoard, boardTasks, initialStep } = await resolveDraft(board);
      setMode({ kind: 'wizard', draft: { board: resolvedBoard, boardTasks }, initialStep });
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
        initialStep={mode.initialStep}
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
        onSelect={(slot) => {
          if (!ensureRecurringAllowed()) return;
          setMode({ kind: 'wizard', prefilledRecurringTimeframe: slot.timeframe });
        }}
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

      {showPaywall && <ProPaywall onClose={() => setShowPaywall(false)} />}
    </div>
  );
}
