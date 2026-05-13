import { useState } from 'react';
import { DEFAULT_USER_PREFERENCES } from '@oybc/shared';
import { CreateHubPage } from '../../pages/CreateHubPage';
import { PLAYGROUND_USER_ID } from './playgroundUtils';
import styles from './CreateHubPlayground.module.css';

/**
 * CreateHubPlayground — Playground harness for the full Create Hub
 * flow. Mounts the production `CreateHubPage` with the playground
 * user and synced-default preferences so the hub → wizard → hub
 * loop can be flexed without any auth or router plumbing.
 *
 * Replaces the earlier wizard-only `BoardWizardShellPlayground`: the
 * hub contains the wizard, so this playground exercises everything
 * the previous one did plus the hub itself (CTA card, drafts list,
 * library count, quick-add).
 */
export function CreateHubPlayground(): React.ReactElement {
  const [log, setLog] = useState<string[]>([]);

  function appendLog(line: string): void {
    setLog((prev) => [`${new Date().toLocaleTimeString()} — ${line}`, ...prev].slice(0, 8));
  }

  return (
    <div className={styles.container}>
      <div className={styles.harnessNote}>
        Hub + wizard mount with <code>DEFAULT_USER_PREFERENCES</code> and the
        playground user. Save a draft, then return to the hub — the draft appears
        in the Drafts list.
      </div>

      <CreateHubPage
        userId={PLAYGROUND_USER_ID}
        preferences={DEFAULT_USER_PREFERENCES}
        onBoardCompleted={(boardId, status) =>
          appendLog(
            `${status === 'active' ? 'Activated' : 'Saved draft'}: boardId=${boardId.slice(
              0,
              8,
            )}…`,
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
