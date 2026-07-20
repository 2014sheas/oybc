import { useMemo, useState } from 'react';
import type { Pool, RecurringBoardTemplate, Task } from '@oybc/shared';
import { usePools, useRecurringBoardTemplates, useTasks } from '../../hooks';
import { PoolCard } from './PoolCard';
import { PoolEditSheet } from './PoolEditSheet';
import { computePoolHealthByPoolId } from './poolHealthBatch';
import styles from './PoolsBrowse.module.css';

export interface PoolsBrowseProps {
  userId: string;
}

/** Sheet visibility: closed, creating a new pool, or editing an existing one. */
type SheetState = { kind: 'closed' } | { kind: 'create' } | { kind: 'edit'; pool: Pool };

// Stable empty fallback for `useTasks(userId) ?? FALLBACK` — see
// `useTaskLibrary.ts`'s `EMPTY_TASKS` for the rationale (a fresh `[]`
// literal on every render would defeat the `useMemo` below's dep check).
const EMPTY_TASKS = Object.freeze([]) as unknown as Task[];

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
 */
export function PoolsBrowse({ userId }: PoolsBrowseProps): React.ReactElement {
  const pools = usePools(userId);
  const templates = useRecurringBoardTemplates(userId);
  const tasks = useTasks(userId) ?? EMPTY_TASKS;
  const [sheet, setSheet] = useState<SheetState>({ kind: 'closed' });

  const tasksById = useMemo(() => {
    const m: Record<string, Task> = {};
    for (const t of tasks) m[t.id] = t;
    return m;
  }, [tasks]);

  const templatesById = useMemo(() => {
    const m: Record<string, RecurringBoardTemplate> = {};
    for (const t of templates) m[t.id] = t;
    return m;
  }, [templates]);

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
              templatesById={templatesById}
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
          allTasks={tasks}
          onClose={closeSheet}
          onSaved={closeSheet}
          onDeleted={closeSheet}
        />
      )}
    </div>
  );
}
