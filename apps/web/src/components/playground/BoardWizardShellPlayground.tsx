import { useState } from 'react';
import { DEFAULT_USER_PREFERENCES } from '@oybc/shared';
import { BoardWizardPage } from '../../pages/BoardWizardPage';
import { PLAYGROUND_USER_ID } from './playgroundUtils';
import styles from './BoardWizardShellPlayground.module.css';

/**
 * BoardWizardShellPlayground — Spike harness for build-sequence step 2
 * of the board-creation UX redesign.
 *
 * Mounts the production `BoardWizardPage` with `DEFAULT_USER_PREFERENCES`
 * and the playground user. Cancel / complete callbacks just append a
 * line to the activity log so the wizard can be exercised end-to-end
 * without any production routing or DB writes from the stubbed step 3.
 */
export function BoardWizardShellPlayground(): React.ReactElement {
  const [log, setLog] = useState<string[]>([]);
  const [wizardKey, setWizardKey] = useState(0);

  function appendLog(line: string): void {
    setLog((prev) => [`${new Date().toLocaleTimeString()} — ${line}`, ...prev].slice(0, 8));
  }

  return (
    <div className={styles.container}>
      <div className={styles.harness}>
        <button
          type="button"
          className={styles.harnessButton}
          onClick={() => {
            setWizardKey((k) => k + 1);
            appendLog('Wizard reset.');
          }}
        >
          Reset wizard
        </button>
        <span className={styles.harnessNote}>
          Wizard mounts with DEFAULT_USER_PREFERENCES + the playground user.
        </span>
      </div>

      <BoardWizardPage
        key={wizardKey}
        userId={PLAYGROUND_USER_ID}
        preferences={DEFAULT_USER_PREFERENCES}
        onCancel={() => appendLog('Cancel tapped (would close wizard / show smart prompt in step 4).')}
        onComplete={(boardId, status) =>
          appendLog(
            `${status === 'active' ? 'Activate' : 'Save Draft'} tapped → boardId=${boardId} (stub).`,
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
