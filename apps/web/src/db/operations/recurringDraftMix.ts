import { resolveMix, type Pool, type Task } from '@oybc/shared';
import { db } from '../internal';
import { decodeRecurringDraftMix } from '../recurringDraftMix';

/**
 * Resolves a recurring draft's raw `recurringDraftMix` JSON into the
 * concrete, deterministically-ordered task-id mix it describes —
 * `resolveMix`'s ordered result over the pools/tasks the mix references.
 *
 * Board Creation Split (web PR D) — used by `useRecurringDraftMix` (reactive
 * hook, for wizard hydration) and `useResumableDraft` (one-shot, for the
 * draft-resume initial-step computation). Mirrors iOS
 * `BoardWizardViewModel.resolvePoolMixHydration`'s DB-lookup shape: fetch
 * only the referenced pools, then only the referenced tasks, then delegate
 * to the shared `resolveMix` algorithm.
 *
 * Returns `[]` (never throws) for a missing/malformed mix or an unresolvable
 * reference — a fresh recurring draft's mix is the only shape that has ever
 * existed, so there's no legacy fallback to preserve; the wizard still
 * opens with an empty selection and the user rebuilds the pool.
 */
export async function resolveRecurringDraftMixTaskIds(
  mixJson: string | undefined,
): Promise<string[]> {
  const mix = decodeRecurringDraftMix(mixJson);

  const pools: Pool[] =
    mix.poolIds.length > 0 ? await db.pools.where('id').anyOf(mix.poolIds).toArray() : [];
  const poolsById: Record<string, Pool> = {};
  for (const p of pools) poolsById[p.id] = p;

  const referencedIds = new Set<string>();
  for (const p of pools) for (const id of p.taskIds) referencedIds.add(id);
  for (const id of mix.manualTaskIds) referencedIds.add(id);

  const tasks: Task[] =
    referencedIds.size > 0
      ? await db.tasks.where('id').anyOf(Array.from(referencedIds)).toArray()
      : [];
  const tasksById: Record<string, Task> = {};
  for (const t of tasks) tasksById[t.id] = t;

  return resolveMix(mix, poolsById, tasksById).taskIds;
}
