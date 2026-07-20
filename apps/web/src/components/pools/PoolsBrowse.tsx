import { useMemo, useState } from 'react';
import type { Pool, Task } from '@oybc/shared';
import { useRecurringBoardTemplates } from '../../hooks';
import { PoolCard } from './PoolCard';
import { PoolEditSheet } from './PoolEditSheet';
import { computePoolHealthByPoolId } from './poolHealthBatch';
import styles from './PoolsBrowse.module.css';

export interface PoolsBrowseProps {
  userId: string;
  /** The user's non-deleted pools — loaded ONCE at `TasksPage` (it already
   *  needs the count for the segment's "Pools · N" label) and passed down
   *  rather than re-subscribed here, so Pools mode doesn't run two
   *  concurrent `usePools` live queries (`useLiveQuery` doesn't dedupe). */
  pools: Pool[];
  /** The user's full non-deleted task library — likewise already loaded at
   *  `TasksPage` via `useTaskLibrary`; reused here instead of a second
   *  `useTasks` subscription. */
  allTasks: Task[];
}

/** Sheet visibility: closed, creating a new pool, or editing an existing one. */
type SheetState = { kind: 'closed' } | { kind: 'create' } | { kind: 'edit'; pool: Pool };

/**
 * PoolsBrowse — the Tasks-tab "Pools" segment (Task Pools + Recurring
 * Boards Rework, P2). Lists the user's pools as cards + a dashed
 * "+ New pool" entry; tapping a card (or "+ New pool") opens
 * `PoolEditSheet`. See docs/POOLS_RECURRING.md §Surfaces item 1 +
 * the handoff screenshot `01-pools.png`.
 *
 * **NO board-related actions anywhere on this surface** (locked decision)
 * — pools are populated here; boards pull them in from the wizard side.
 *
 * Health (the red short-warning line) is computed ONCE per render via
 * `computePoolHealthByPoolId` over the already-loaded pools/templates/
 * tasks — never per-card — per the repo's perf-constraint history.
 * `pools`/`allTasks` are props (not local live queries) for the same
 * single-read-set reason — see the props' docstrings.
 */
export function PoolsBrowse({ userId, pools, allTasks }: PoolsBrowseProps): React.ReactElement {
  const templates = useRecurringBoardTemplates(userId);
  const [sheet, setSheet] = useState<SheetState>({ kind: 'closed' });

  const tasksById = useMemo(() => {
    const m: Record<string, Task> = {};
    for (const t of allTasks) m[t.id] = t;
    return m;
  }, [allTasks]);

  const healthByPoolId = useMemo(
    () => computePoolHealthByPoolId(pools, templates, tasksById),
    [pools, templates, tasksById],
  );

  const poolTasksById = useMemo(() => {
    const m: Record<string, Task[]> = {};
    for (const pool of pools) {
      m[pool.id] = pool.taskIds
        .map((id) => tasksById[id])
        .filter((t): t is Task => t !== undefined);
    }
    return m;
  }, [pools, tasksById]);

  const closeSheet = (): void => setSheet({ kind: 'closed' });

  return (
    <div className={styles.shell}>
      <p className={styles.intro}>Keep like tasks together. Any board can draw from a pool.</p>

      {pools.length > 0 && (
        <div className={styles.list}>
          {pools.map((pool) => (
            <PoolCard
              key={pool.id}
              pool={pool}
              tasks={poolTasksById[pool.id] ?? []}
              health={healthByPoolId[pool.id] ?? { taskCount: 0, consumers: [] }}
              onClick={(p) => setSheet({ kind: 'edit', pool: p })}
            />
          ))}
        </div>
      )}

      <button
        type="button"
        className={styles.newPoolButton}
        onClick={() => setSheet({ kind: 'create' })}
      >
        + New pool
      </button>

      {sheet.kind !== 'closed' && (
        <PoolEditSheet
          userId={userId}
          pool={sheet.kind === 'edit' ? sheet.pool : undefined}
          templates={templates}
          allTasks={allTasks}
          onClose={closeSheet}
          onSaved={closeSheet}
          onDeleted={closeSheet}
        />
      )}
    </div>
  );
}
