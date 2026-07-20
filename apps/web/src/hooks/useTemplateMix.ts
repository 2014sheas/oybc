import { useLiveQuery } from 'dexie-react-hooks';
import { resolveMix, type Pool, type RecurringBoardTemplate, type Task } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * Resolves a `RecurringBoardTemplate`'s CURRENT pool-mix task ids,
 * reactively.
 *
 * P1 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Migration "seedTaskIds end state") rewired the legacy template editor's
 * persistence to write edits through to the linked `Pool`'s `taskIds`
 * instead of the template's own `seedTaskIds` field — which is left
 * VERBATIM (decode-compat only) and never read again. That means the
 * wizard's template-edit hydration (`useBoardWizard`'s `selectedTaskIds`
 * initial state) can no longer read `effectiveTemplate.seedTaskIds`
 * directly: after a first "Add tasks"/"Edit" round-trip, that field is
 * stale — it would silently drop whatever the write-through already
 * applied to the Pool, and re-opening the wizard a second time would show
 * (and then re-save, DESTRUCTIVELY) the wrong selection.
 *
 * Used by `useBoardWizard`. Returns `undefined` while loading / when
 * there's no template to resolve, matching `useDefaultPool`'s tri-state
 * convention so callers can distinguish "still loading" from "resolved".
 */
export function useTemplateMix(
  template: RecurringBoardTemplate | undefined,
): Set<string> | undefined {
  return useLiveQuery(async (): Promise<Set<string> | undefined> => {
    if (!template) return undefined;

    // Un-migrated safety net (shouldn't occur post-migration — the
    // first-launch migration always stamps `poolIds`): fall back to
    // `seedTaskIds` verbatim when the generalized fields are absent.
    if (template.poolIds === undefined) return new Set(template.seedTaskIds);

    const poolIds = template.poolIds;
    const pools: Pool[] =
      poolIds.length > 0 ? await db.pools.where('id').anyOf(poolIds).toArray() : [];
    const poolsById: Record<string, Pool> = {};
    for (const p of pools) poolsById[p.id] = p;

    // resolveMix needs a tasksById map to filter each pool's OWN
    // resolvable supply (deleted tasks skipped); the manual layer passes
    // through verbatim and doesn't need deletion-filtering, but including
    // manual ids here means a soft-deleted manual task still resolves to
    // its Task row (letting a caller detect it, same contract as the
    // spawn path).
    const referencedIds = new Set<string>();
    for (const p of pools) for (const id of p.taskIds) referencedIds.add(id);
    for (const id of template.manualTaskIds ?? []) referencedIds.add(id);

    const tasks: Task[] =
      referencedIds.size > 0
        ? await db.tasks.where('id').anyOf(Array.from(referencedIds)).toArray()
        : [];
    const tasksById: Record<string, Task> = {};
    for (const t of tasks) tasksById[t.id] = t;

    return new Set(resolveMix(template, poolsById, tasksById).taskIds);
  }, [template]);
}
