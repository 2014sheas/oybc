import { useLiveQuery } from 'dexie-react-hooks';
import { resolveMix, type Pool, type RecurringBoardTemplate, type Task } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * Batched, container-level counterpart to `useTemplateMix` — resolves
 * EVERY template's CURRENT pool-mix task ids in one pass (two batched
 * Dexie queries: all referenced pools, all referenced tasks) rather than
 * one query per row. Used by `RecurringTemplatesPage` for the pool
 * preview / "N-task pool" meta / "needs attention" badge computations,
 * which used to read `template.seedTaskIds` directly per row — stale
 * post-P1 write-through (docs/POOLS_RECURRING.md §Migration "seedTaskIds
 * end state": "never read after P1" is unconditional, not just the
 * wizard hydration case `useTemplateMix` was built for).
 *
 * Batched, not per-row: mirrors the boards-list perf lesson (N rows must
 * not mean N independent Dexie round-trips) — one `anyOf` query per
 * table for the whole page, however many templates it lists.
 *
 * The Dexie orchestration here (`useTemplateMixes`) is a thin wrapper
 * around the pure `computeTemplateMixes`, which does the actual
 * per-template `resolveMix` fan-out + the empty-`poolIds` fallback (see
 * `useTemplateMix`'s docstring for why `poolIds === []` also falls back
 * to `seedTaskIds`). Splitting them out keeps the resolution logic
 * testable without a DOM/hook-render harness (this repo's Vitest setup
 * is `environment: 'node'` — see `vitest.config.ts` — so hooks that call
 * `useLiveQuery` can't be exercised directly; `wizardTimeframeSeed.ts`
 * establishes the same pure-extraction precedent for `useBoardWizard`).
 *
 * Returns `undefined` while loading, matching `useTemplateMix`'s
 * tri-state convention.
 */
export function useTemplateMixes(
  templates: RecurringBoardTemplate[],
): Record<string, string[]> | undefined {
  return useLiveQuery(async (): Promise<Record<string, string[]>> => {
    if (templates.length === 0) return {};

    const migrated = templates.filter(
      (t) => t.poolIds !== undefined && t.poolIds.length > 0,
    );

    const allPoolIds = new Set<string>();
    for (const t of migrated) for (const id of t.poolIds ?? []) allPoolIds.add(id);

    const pools: Pool[] =
      allPoolIds.size > 0
        ? await db.pools.where('id').anyOf(Array.from(allPoolIds)).toArray()
        : [];
    const poolsById: Record<string, Pool> = {};
    for (const p of pools) poolsById[p.id] = p;

    const allTaskIds = new Set<string>();
    for (const p of pools) for (const id of p.taskIds) allTaskIds.add(id);
    for (const t of migrated) for (const id of t.manualTaskIds ?? []) allTaskIds.add(id);

    const tasks: Task[] =
      allTaskIds.size > 0
        ? await db.tasks.where('id').anyOf(Array.from(allTaskIds)).toArray()
        : [];
    const tasksById: Record<string, Task> = {};
    for (const t of tasks) tasksById[t.id] = t;

    return computeTemplateMixes(templates, poolsById, tasksById);
  }, [templates]);
}

/**
 * Pure per-template mix resolution given ALREADY-BATCHED `poolsById` /
 * `tasksById` lookups. Exported separately from the hook above so it can
 * be unit-tested without a Dexie/React harness — see
 * `hooks/__tests__/useTemplateMixes.test.ts`.
 *
 * Same "empty poolIds falls back to seedTaskIds" rule as `useTemplateMix`
 * (see that hook's docstring for the full rationale) — kept identical
 * here rather than re-derived so the batched and single-template paths
 * can never drift.
 */
export function computeTemplateMixes(
  templates: RecurringBoardTemplate[],
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const t of templates) {
    if (t.poolIds === undefined || t.poolIds.length === 0) {
      out[t.id] = t.seedTaskIds;
      continue;
    }
    out[t.id] = resolveMix(t, poolsById, tasksById).taskIds;
  }
  return out;
}
