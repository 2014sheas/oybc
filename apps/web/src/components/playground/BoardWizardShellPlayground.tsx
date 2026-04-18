import { useCallback, useState } from 'react';
import { BoardStatus, DEFAULT_USER_PREFERENCES } from '@oybc/shared';
import { fetchBoards } from '../../db/operations/boards';
import { fetchBoardTasks } from '../../db/operations/boardTasks';
import { BoardWizardPage } from '../../pages/BoardWizardPage';
import type { BoardWizardDraft } from '../../pages/createHub/useBoardWizard';
import { PLAYGROUND_USER_ID } from './playgroundUtils';
import styles from './BoardWizardShellPlayground.module.css';

/**
 * BoardWizardShellPlayground — Playground harness for the wizard.
 *
 * Mounts the production `BoardWizardPage` with `DEFAULT_USER_PREFERENCES`
 * and the playground user. Exposes a "Resume latest draft" control
 * that hydrates the wizard from the most recent DRAFT board in the
 * local DB so the draft-hydration path can be flexed end-to-end.
 */
export function BoardWizardShellPlayground(): React.ReactElement {
  const [log, setLog] = useState<string[]>([]);
  const [wizardKey, setWizardKey] = useState(0);
  const [draft, setDraft] = useState<BoardWizardDraft | undefined>(undefined);
  const [resumeStatus, setResumeStatus] = useState<string | null>(null);
  const [isResuming, setIsResuming] = useState(false);

  function appendLog(line: string): void {
    setLog((prev) => [`${new Date().toLocaleTimeString()} — ${line}`, ...prev].slice(0, 8));
  }

  function resetWizardFresh(): void {
    setDraft(undefined);
    setWizardKey((k) => k + 1);
    setResumeStatus(null);
  }

  const handleResumeDraft = useCallback(async (): Promise<void> => {
    setIsResuming(true);
    setResumeStatus(null);
    try {
      const boards = await fetchBoards(PLAYGROUND_USER_ID);
      const drafts = boards
        .filter((b) => b.status === BoardStatus.DRAFT && !b.isDeleted)
        .sort((a, b) => (b.createdAt > a.createdAt ? 1 : -1));
      const latest = drafts[0];
      if (latest === undefined) {
        setResumeStatus('No drafts found. Save one from the wizard first.');
        return;
      }
      const boardTasks = await fetchBoardTasks(latest.id);
      setDraft({ board: latest, boardTasks });
      setWizardKey((k) => k + 1);
      setResumeStatus(
        `Resumed draft "${latest.name}" — ${boardTasks.length} task${
          boardTasks.length === 1 ? '' : 's'
        } restored.`,
      );
      appendLog(`Resumed draft boardId=${latest.id.slice(0, 8)}…`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Unknown error.';
      setResumeStatus(`Failed to resume: ${msg}`);
    } finally {
      setIsResuming(false);
    }
  }, []);

  return (
    <div className={styles.container}>
      <div className={styles.harness}>
        <button
          type="button"
          className={styles.harnessButton}
          onClick={() => {
            resetWizardFresh();
            appendLog('Wizard reset.');
          }}
        >
          Reset wizard (fresh)
        </button>
        <button
          type="button"
          className={styles.harnessButton}
          onClick={() => void handleResumeDraft()}
          disabled={isResuming}
        >
          {isResuming ? 'Loading…' : 'Resume latest draft'}
        </button>
        <span className={styles.harnessNote}>
          {draft !== undefined
            ? `Resumed: "${draft.board.name}" (${draft.boardTasks.length} tasks)`
            : 'Wizard mounts fresh with DEFAULT_USER_PREFERENCES + the playground user.'}
        </span>
      </div>

      {resumeStatus && <div className={styles.harnessNote}>{resumeStatus}</div>}

      <BoardWizardPage
        key={wizardKey}
        userId={PLAYGROUND_USER_ID}
        preferences={DEFAULT_USER_PREFERENCES}
        draft={draft}
        onCancel={() => appendLog('Cancel resolved — wizard dismissed.')}
        onComplete={(boardId, status) =>
          appendLog(
            `${status === 'active' ? 'Activated' : 'Saved draft'}: boardId=${boardId.slice(0, 8)}…`,
          )
        }
      />

      {log.length > 0 && (
        <div className={styles.log}>
          <h5 className={styles.logHeader}>Activity</h5>
          {log.map((entry, i) => (
            <div key={i} className={styles.logEntry}>
              {entry}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
