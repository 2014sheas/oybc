import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { Pool } from '@oybc/shared';
import { PoolEditorBody } from '../components/pools/PoolEditorBody';
import { fetchPool } from '../db/operations/pools';
import { useRecurringBoardTemplatesQuery } from '../hooks';
import { useBrowsableTasks, useTaskLibrary } from './createPage/useTaskLibrary';
import { TASKS_POOLS_PATH } from './tasks/tasksSegment';
import styles from './PoolEditorPage.module.css';

export interface PoolEditorPageProps {
  /** Authenticated user id. */
  userId: string;
  /** The pool being edited; `undefined` ⇒ create mode ("New pool"). */
  poolId?: string;
}

/**
 * PoolEditorPage — the full-screen pool editor (`/tasks/pools/new`,
 * `/tasks/pools/:id`), the pool twin of the board wizard: same chrome family
 * as `BoardWizardPage` (kicker + title billboard, ✕ close), body =
 * `PoolEditorBody` (the wizard's Tasks-step rows + inline row editor).
 * Save / Cancel / Delete / ✕ all return to the Tasks tab's Pools segment.
 * See docs/POOLS_RECURRING.md §Surfaces item 2.
 */
export function PoolEditorPage({ userId, poolId }: PoolEditorPageProps): React.ReactElement | null {
  const navigate = useNavigate();
  const library = useTaskLibrary(userId);
  const browsableTasks = useBrowsableTasks(library.allTasks, library.childToParents);
  const templates = useRecurringBoardTemplatesQuery(userId);

  // One-shot read: the editor seeds its state once from the pool. `undefined`
  // = loading, `null` = not found (deleted / foreign id) → back to Pools.
  const [pool, setPool] = useState<Pool | null | undefined>(undefined);
  useEffect(() => {
    if (poolId === undefined) return;
    let cancelled = false;
    void fetchPool(poolId).then((p) => {
      if (!cancelled) setPool(p && !p.isDeleted && p.userId === userId ? p : null);
    });
    return () => {
      cancelled = true;
    };
  }, [poolId, userId]);

  const back = (): void => {
    void navigate(TASKS_POOLS_PATH);
  };

  useEffect(() => {
    if (pool === null) navigate(TASKS_POOLS_PATH, { replace: true });
  }, [pool, navigate]);

  const isEdit = poolId !== undefined;
  // First paint is final paint: wait for the pool and the templates (deck
  // floor) before mounting the form that seeds from them.
  if (isEdit && pool === undefined) return null;
  if (pool === null || templates === undefined) return null;

  return (
    <div className={styles.shell}>
      <header className={styles.header}>
        <div className={styles.headerText}>
          <p className={styles.kicker}>{isEdit ? 'EDIT POOL' : 'NEW POOL'}</p>
          <h2 className={styles.title}>Pool</h2>
        </div>
        <button type="button" className={styles.closeButton} onClick={back} aria-label="Close pool editor">
          ✕
        </button>
      </header>

      <PoolEditorBody
        userId={userId}
        pool={pool ?? undefined}
        templates={templates}
        allTasks={library.allTasks}
        browsableTasks={browsableTasks}
        onCancel={back}
        onSaved={back}
        onDeleted={back}
      />
    </div>
  );
}
