import { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import type { Pool, Task } from '@oybc/shared';
import { useRecurringBoardTemplatesQuery, useTemplateRosterHealth } from '../../hooks';
import { PoolCard } from './PoolCard';
import { computePoolHealthByPoolId, isPoolHealthResolved } from './poolHealthBatch';
import { NEW_POOL_PATH, poolEditorPath } from '../../pages/tasks/tasksSegment';
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
   *  `useTasks` subscription. Feeds card/health resolution. */
  allTasks: Task[];
}

/**
 * PoolsBrowse — the Tasks-tab "Pools" segment (Task Pools + Recurring
 * Boards Rework, P2). Lists the user's pools as cards + a dashed
 * "+ New pool" entry; tapping a card (or "+ New pool") routes to
 * the full-screen `PoolEditorPage`. See docs/POOLS_RECURRING.md §Surfaces item 1 +
 * the handoff screenshot `01-pools.png`.
 *
 * **NO board-related actions anywhere on this surface** (locked decision)
 * — pools are populated here; boards pull them in from the wizard side.
 *
 * Health (the red short-warning line) is computed ONCE per render via
 * `computePoolHealthByPoolId` over the already-loaded pools/templates/
 * tasks plus the roster's batched achievable picks
 * (`useTemplateRosterHealth`) — never per-card — per the repo's
 * perf-constraint history.
 * `pools`/`allTasks` are props (not local live queries) for the same
 * single-read-set reason — see the props' docstrings.
 *
 * First paint is final paint: until the templates query AND the roster's
 * achievable picks have resolved for every template
 * (`isPoolHealthResolved`), the card list renders a loading line instead
 * of warning-less cards — otherwise "Short on N boards" would pop in after
 * the cards painted (the late-mutation rule).
 */
export function PoolsBrowse({
  userId,
  pools,
  allTasks,
}: PoolsBrowseProps): React.ReactElement {
  // Tri-state: `undefined` until read, so "no templates" isn't confused
  // with "not loaded yet" (which would paint cards before their warning).
  const templatesQuery = useRecurringBoardTemplatesQuery(userId);
  const templates = useMemo(() => templatesQuery ?? [], [templatesQuery]);
  // Sources-native health input (2026-09 audit T2): each repeating
  // board's achievable pick, resolved the way its next spawn would.
  const rosterHealth = useTemplateRosterHealth(templates);
  const healthResolved = isPoolHealthResolved(templatesQuery, rosterHealth?.mixByTemplateId);
  const navigate = useNavigate();

  const tasksById = useMemo(() => {
    const m: Record<string, Task> = {};
    for (const t of allTasks) m[t.id] = t;
    return m;
  }, [allTasks]);

  const healthByPoolId = useMemo(
    () =>
      computePoolHealthByPoolId(pools, templates, rosterHealth?.mixByTemplateId, tasksById),
    [pools, templates, rosterHealth, tasksById],
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

  return (
    <div className={styles.shell}>
      <p className={styles.intro}>Keep like tasks together. Any board can draw from a pool.</p>

      {pools.length > 0 && !healthResolved && (
        <p className={styles.loading} role="status" data-testid="pools-browse-loading">
          Loading pools…
        </p>
      )}

      {pools.length > 0 && healthResolved && (
        <div className={styles.list}>
          {pools.map((pool) => (
            <PoolCard
              key={pool.id}
              pool={pool}
              tasks={poolTasksById[pool.id] ?? []}
              health={healthByPoolId[pool.id] ?? { taskCount: 0, consumers: [] }}
              onClick={(p) => navigate(poolEditorPath(p.id))}
            />
          ))}
        </div>
      )}

      <button
        type="button"
        className={styles.newPoolButton}
        onClick={() => navigate(NEW_POOL_PATH)}
      >
        + New pool
      </button>
    </div>
  );
}
