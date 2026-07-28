import { computePoolHealth } from '@oybc/shared';
import type { Pool, PoolHealthResult, RecurringBoardTemplate, Task } from '@oybc/shared';

/**
 * Batches `computePoolHealth` across every pool on the Pools browse
 * surface — ONE pass over the (already-loaded) `templates`/`tasksById`
 * lookups, never a per-card query (this repo has been burned twice by
 * per-card DB reads; see CLAUDE.md's perf-constraint note for P2 Task 2).
 *
 * Callers load `pools` (`usePools`), `templates`
 * (`useRecurringBoardTemplates`), and `tasksById` (built once from
 * `useTasks`) at the page level and pass them in here; this function does
 * no I/O of its own.
 */
export function computePoolHealthByPoolId(
  pools: readonly Pool[],
  templates: readonly RecurringBoardTemplate[],
  tasksById: Record<string, Task>,
): Record<string, PoolHealthResult> {
  const poolsById: Record<string, Pool> = {};
  for (const pool of pools) poolsById[pool.id] = pool;

  const result: Record<string, PoolHealthResult> = {};
  for (const pool of pools) {
    result[pool.id] = computePoolHealth(pool, {
      templates: templates as RecurringBoardTemplate[],
      poolsById,
      tasksById,
    });
  }
  return result;
}
