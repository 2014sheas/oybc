import { useCallback, useState } from 'react';
import type { Board, UserPreferences } from '@oybc/shared';
import { fetchBoardTasks } from '../db/operations/boardTasks';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { useDrafts } from './createHub/useDrafts';
import { BoardWizardPage } from './BoardWizardPage';
import { CreateHubBoardCTA } from '../components/createHub/CreateHubBoardCTA';
import { CreateHubDraftsList } from '../components/createHub/CreateHubDraftsList';
import { CreateHubQuickAdd } from '../components/createHub/CreateHubQuickAdd';
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
}

type HubMode =
  | { kind: 'hub' }
  | { kind: 'wizard'; draft?: BoardWizardDraft };

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
 */
export function CreateHubPage({
  userId,
  preferences,
  onBoardCompleted,
}: CreateHubPageProps): React.ReactElement {
  const [mode, setMode] = useState<HubMode>({ kind: 'hub' });
  const drafts = useDrafts(userId);
  const library = useTaskLibrary(userId);

  const returnToHub = useCallback(() => setMode({ kind: 'hub' }), []);

  const handleStartBoard = useCallback(() => {
    setMode({ kind: 'wizard' });
  }, []);

  const handleResumeDraft = useCallback(
    async (board: Board): Promise<void> => {
      const boardTasks = await fetchBoardTasks(board.id);
      setMode({ kind: 'wizard', draft: { board, boardTasks } });
    },
    [],
  );

  const handleWizardComplete = useCallback(
    (boardId: string, status: 'active' | 'draft'): void => {
      onBoardCompleted?.(boardId, status);
      returnToHub();
    },
    [onBoardCompleted, returnToHub],
  );

  if (mode.kind === 'wizard') {
    return (
      <BoardWizardPage
        userId={userId}
        preferences={preferences}
        draft={mode.draft}
        onCancel={returnToHub}
        onComplete={handleWizardComplete}
      />
    );
  }

  // Under the unified compound model, composites live in `allTasks` with
  // type='compound' — counting them separately would double-count. The
  // library count is just the size of allTasks (incl. compounds).
  const libraryCount = library.allTasks.length;

  return (
    <div className={styles.shell}>
      <header className={styles.header}>
        <h1 className={styles.title}>Create</h1>
      </header>

      <CreateHubBoardCTA onClick={handleStartBoard} />

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
