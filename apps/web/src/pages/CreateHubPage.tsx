import { useCallback, useState } from 'react';
import {
  type Board,
  type RecurringBoardTemplate,
  type Timeframe,
  type UserPreferences,
} from '@oybc/shared';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { useDrafts } from './createHub/useDrafts';
import { useRecurringTimeframeParam } from './createHub/useRecurringTimeframeParam';
import { useEditTemplateParam } from './createHub/useEditTemplateParam';
import { useResumableDraft } from './createHub/useResumableDraft';
import { usePendingRecurringBoards } from '../hooks';
import { BoardWizardPage } from './BoardWizardPage';
import { CreateHubBoardCTA } from '../components/createHub/CreateHubBoardCTA';
import { CreateHubDraftsList } from '../components/createHub/CreateHubDraftsList';
import { CreateHubQuickAdd } from '../components/createHub/CreateHubQuickAdd';
import { PendingCoreBoardsSection } from '../components/PendingCoreBoardsSection';
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
   *  Profile templates list (`/profile/recurring-templates`) rather
   *  than `/boards/${id}`. */
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
      /** Set when the wizard was launched from Profile → Recurring
       *  templates → Edit (`/create?editTemplate=<uuid>`). All fields
       *  hydrate from the template, `isRecurring` is forced ON, and
       *  Save updates the template instead of creating a new board. */
      editingTemplate?: RecurringBoardTemplate;
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
 * - Library section: shows the user's task count (navigating to a
 *   full library browser is a later enhancement).
 * - `CreateHubQuickAdd`: inline task-creation form that writes to
 *   the library only.
 *
 * The hub owns the wizard-mount state so the two surfaces transition
 * in-place. Dismissing the wizard (Cancel / Activate / Save Draft)
 * returns to the hub; the reactive `useDrafts` hook ensures any
 * newly-saved draft appears immediately in the list.
 *
 * Two deep-link entry points are handled by dedicated hooks:
 * - `?recurringTimeframe=daily` → `useRecurringTimeframeParam`
 * - `?editTemplate=<uuid>` → `useEditTemplateParam`
 * Each consumes its param exactly once and clears it from the URL so a
 * wizard cancel + manual re-entry doesn't re-arm the prefill.
 */
export function CreateHubPage({
  userId,
  preferences,
  onBoardCompleted,
  onTemplateCompleted,
}: CreateHubPageProps): React.ReactElement {
  const [mode, setMode] = useState<HubMode>({ kind: 'hub' });
  const drafts = useDrafts(userId);
  const library = useTaskLibrary(userId);
  const pendingRecurring = usePendingRecurringBoards(userId);
  const resolveDraft = useResumableDraft();

  useRecurringTimeframeParam(
    useCallback((timeframe: Timeframe) => {
      setMode({ kind: 'wizard', prefilledRecurringTimeframe: timeframe });
    }, []),
  );

  useEditTemplateParam(
    useCallback((template: RecurringBoardTemplate) => {
      setMode({ kind: 'wizard', editingTemplate: template });
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
        editingTemplate={mode.editingTemplate}
        onCancel={returnToHub}
        onComplete={handleWizardComplete}
        onTemplateComplete={handleTemplateComplete}
      />
    );
  }

  // Under the unified compound model, composites live in `allTasks` with
  // type='compound' — counting them separately would double-count. The
  // library count is just the size of allTasks (incl. compounds).
  const libraryCount = library.allTasks.length;

  // Phase 6.1d: when there are pending core boards, they become the
  // headline action and the "Start a new board" custom CTA is demoted to
  // a smaller secondary affordance. When the section short-circuits to
  // null (all 4 windows already covered, or all 4 prefs disabled), the
  // custom CTA stays as the primary headline — back-compat for users
  // who've created everything for the current period.
  const hasPendingCoreBoards = pendingRecurring.length > 0;

  return (
    <div className={styles.shell}>
      <header className={styles.header}>
        <h1 className={styles.title}>Create</h1>
      </header>

      <PendingCoreBoardsSection
        pending={pendingRecurring}
        variant="create-tab"
        onCreate={(entry) =>
          // Skip the URL round-trip used by the Boards-tab variant — we're
          // already on /create, so just flip mode directly. Same end state
          // as consuming the URL param via the useRecurringTimeframeParam
          // hook above.
          setMode({ kind: 'wizard', prefilledRecurringTimeframe: entry.timeframe })
        }
      />

      <CreateHubBoardCTA
        onClick={handleStartBoard}
        variant={hasPendingCoreBoards ? 'secondary' : 'primary'}
      />

      {drafts.length > 0 && (
        <CreateHubDraftsList
          drafts={drafts}
          onResume={(d) => void handleResumeDraft(d)}
        />
      )}

      <section className={styles.librarySection}>
        <h3 className={styles.librarySectionHeading}>Your task library</h3>
        <p className={styles.librarySectionMeta}>
          {libraryCount === 0
            ? 'No tasks yet — quick-add below or pick some when you build a board.'
            : `${libraryCount} task${libraryCount === 1 ? '' : 's'} ready to place on a board.`}
        </p>
      </section>

      <CreateHubQuickAdd userId={userId} />
    </div>
  );
}
