import { resolveMix, type Pool, type Task } from '@oybc/shared';
import { db } from '../internal';
import { decodeRecurringDraftMix } from '../recurringDraftMix';

/**
 * Resolves a draft's raw `recurringDraftMix` JSON into the ordered task-id
 * mix its legacy trio (`poolIds` / `manualTaskIds` / `removedTaskIds`)
 * describes, via the shared `resolveMix`. Reads only the trio, not the
 * blob's `sources` — the wizard itself hydrates from `sources`.
 *
 * Callers: `useRecurringDraftMix` (the drafts-list task count in
 * `useDrafts`) and `useResumableDraft` (the draft-resume initial step).
 * Twin of iOS `BoardWizardViewModel.resolvePoolMixHydration`.
 *
 * Returns `[]` (never throws) for a missing/malformed mix or an
 * unresolvable reference.
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
