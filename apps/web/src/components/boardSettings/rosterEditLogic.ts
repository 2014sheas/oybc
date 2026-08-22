import {
  clearRemovalsForUntoggle,
  resolveMix,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';

/**
 * P7 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 9 "Board settings (Profile)" → roster edit sheet) — pure
 * pool-pull / pool-untoggle / manual-add / single-chip-removal logic for
 * the repeating-boards roster's "Edit tasks" sheet.
 *
 * Sibling to `pages/createHub/poolPullLogic.ts` (the wizard's own
 * extraction of the same union-rule bookkeeping), but deliberately a
 * SEPARATE module rather than a shared import: the wizard's functions
 * operate on its local working-state shape (`selectedTaskIds: Set<string>`
 * + `pulledPoolIds: string[]` kept in sync as a flat cache, because the
 * wizard's selection also holds tasks with no pool-mix concept at all —
 * e.g. a one-off board's DefaultPool-style prefill). The roster edit sheet
 * has no such cache to maintain: a `RecurringBoardTemplate`'s mix is fully
 * DERIVED at read time via `resolveMix`, so these functions operate
 * directly on the record's own persisted shape — `{poolIds, manualTaskIds,
 * removedTaskIds}` (arrays, matching `UpdateRecurringBoardTemplateInput`)
 * — and a pool pull/untoggle is nothing more than appending/dropping a
 * pool id; the union math falls out of `resolveMix` automatically. Only
 * `clearRemovalsForUntoggle` is reused from `@oybc/shared` directly (the
 * "supply-based clearing" contract) — `resolvePoolPullAdditions` /
 * `resolvePoolUntoggleRemovals` exist to keep a flat cache in sync, which
 * this state shape doesn't have, so they have no correctness role here
 * (see this module's test file for the worked-example vectors that
 * exercise the same union-rule edge cases as `poolPullLogic.test.ts`,
 * confirming the two extractions can't drift on behavior despite the
 * different state shape).
 *
 * Board Creation Split (web PR D) retired this module's only caller, the
 * `RosterEditSheet` component (Board settings' "Edit tasks" now opens the
 * full `BoardWizardPage` in edit mode instead —
 * `RepeatingBoardWizardOverlay`). Left in place (with `rosterEditLogic.test.ts`
 * still guarding it) as a deferred cleanup rather than deleted alongside
 * the sheet it was extracted from, since a future roster-only quick-edit
 * surface could still want this exact pure logic. Mirrors iOS's identical
 * call on `RepeatingBoardMixEditor.swift` after PR B retired
 * `RepeatingBoardEditSheetView`.
 */

/** The roster's editable mix fields — exactly the persisted
 *  `RecurringBoardTemplate` fields this sheet writes back via
 *  `updateRecurringBoardTemplate(id, {poolIds, manualTaskIds, removedTaskIds})`. */
export interface RosterMix {
  poolIds: string[];
  manualTaskIds: string[];
  removedTaskIds: string[];
}

/**
 * Hydrates a `RosterMix` working copy from a template. Handles the
 * genuinely-un-migrated shape (`poolIds === undefined` — shouldn't occur
 * post-P1 migration, but defensively mirrors `useTemplateMix`'s fallback):
 * flattens `seedTaskIds` into the manual layer rather than reading a
 * pool-mix that was never stamped.
 */
export function hydrateRosterMix(template: RecurringBoardTemplate): RosterMix {
  if (template.poolIds === undefined) {
    return { poolIds: [], manualTaskIds: [...template.seedTaskIds], removedTaskIds: [] };
  }
  return {
    poolIds: [...template.poolIds],
    manualTaskIds: [...(template.manualTaskIds ?? [])],
    removedTaskIds: [...(template.removedTaskIds ?? [])],
  };
}

/**
 * Pull a pool into the roster's mix. Appends `poolId` to `poolIds` — the
 * union with existing supply happens automatically the next time
 * `resolveMix` is called, so there's no separate "additions" step to
 * apply. No-ops (returns the SAME reference) when the pool is missing,
 * soft-deleted, or already pulled.
 */
export function pullPoolIntoRoster(
  poolId: string,
  mix: RosterMix,
  poolsById: Record<string, Pool>,
): RosterMix {
  if (mix.poolIds.includes(poolId)) return mix;
  const pool = poolsById[poolId];
  if (pool === undefined || pool.isDeleted) return mix;
  return { ...mix, poolIds: [...mix.poolIds, poolId] };
}

/**
 * Untoggle (pull out) a pool from the roster's mix. Dropping `poolId` from
 * `poolIds` removes its unioned supply automatically at the next
 * `resolveMix` — the manual layer is never touched (a disjoint field, not
 * derived from pool membership). Also clears now-stale-inert
 * `removedTaskIds` entries via `clearRemovalsForUntoggle` — a removal
 * whose task is no longer supplied by any REMAINING pulled pool is
 * cleared so a future re-pull resurfaces it (§Union rule / removals
 * semantics worked example, docs/POOLS_RECURRING.md).
 */
export function untogglePoolFromRoster(
  poolId: string,
  mix: RosterMix,
  poolsById: Record<string, Pool>,
): RosterMix {
  if (!mix.poolIds.includes(poolId)) return mix;
  const remainingPoolIds = mix.poolIds.filter((id) => id !== poolId);
  const nextRemoved = clearRemovalsForUntoggle(
    { poolIds: mix.poolIds, removedTaskIds: mix.removedTaskIds },
    poolId,
    poolsById,
  );
  return { poolIds: remainingPoolIds, manualTaskIds: mix.manualTaskIds, removedTaskIds: nextRemoved };
}

/**
 * Hand-add a task to the roster's mix. Also clears any stale
 * `removedTaskIds` entry for it — mirrors the wizard's manual-select
 * bookkeeping (`applyManualBookkeepingOnSelect`): manual wins over a
 * prior removal per the mix formula, so a re-add after an explicit remove
 * should not stay suppressed.
 */
export function addManualTaskToRoster(taskId: string, mix: RosterMix): RosterMix {
  if (mix.manualTaskIds.includes(taskId)) return mix;
  return {
    poolIds: mix.poolIds,
    manualTaskIds: [...mix.manualTaskIds, taskId],
    removedTaskIds: mix.removedTaskIds.filter((id) => id !== taskId),
  };
}

/**
 * Remove a single resolved chip from the roster's mix, regardless of its
 * source (the sheet renders every resolved task as a removable chip — see
 * `classifyRosterChip` for the manual/pool provenance that decides its
 * visual treatment, not its removability).
 *
 * Mirrors `applyManualBookkeepingOnDeselect` (`pages/createHub/poolPullLogic.ts`)
 * and iOS `RepeatingBoardMixEditor.removeTaskFromMix`: the manual-drop and
 * the pool-supply check are UNCONDITIONAL and independent, not either/or —
 * a task can be both hand-added AND still supplied by an attached pool
 * (dual-sourced), and dropping it from `manualTaskIds` alone would leave it
 * resurfacing via the pool's union in `resolveMix`. So:
 *
 * - ALWAYS drop it from `manualTaskIds` (no-op if it wasn't there).
 * - ALWAYS check whether it's still supplied by a currently-pulled
 *   (non-deleted) pool; if so, record an explicit removal so it won't
 *   resurface from that supply, regardless of its prior manual membership.
 * - If neither applied (not manual, not pool-supplied — a resolved id
 *   that isn't actually backed by anything, shouldn't occur in steady
 *   state), this is a true no-op and returns the same reference.
 */
export function removeResolvedTaskFromRoster(
  taskId: string,
  mix: RosterMix,
  poolsById: Record<string, Pool>,
): RosterMix {
  const wasManual = mix.manualTaskIds.includes(taskId);
  const nextManual = wasManual
    ? mix.manualTaskIds.filter((id) => id !== taskId)
    : mix.manualTaskIds;
  const suppliedByAPulledPool = mix.poolIds.some((poolId) => {
    const pool = poolsById[poolId];
    return pool !== undefined && !pool.isDeleted && pool.taskIds.includes(taskId);
  });
  if (!suppliedByAPulledPool) {
    if (!wasManual) return mix;
    return { ...mix, manualTaskIds: nextManual };
  }
  if (mix.removedTaskIds.includes(taskId)) {
    return wasManual ? { ...mix, manualTaskIds: nextManual } : mix;
  }
  return {
    poolIds: mix.poolIds,
    manualTaskIds: nextManual,
    removedTaskIds: [...mix.removedTaskIds, taskId],
  };
}

/** Resolves the roster's CURRENT mix task ids (deterministic order — see
 *  `resolveMix`'s docstring), for the sheet's chip list + floor gate. */
export function resolveRosterTaskIds(
  mix: RosterMix,
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): string[] {
  return resolveMix(mix, poolsById, tasksById).taskIds;
}

export type RosterChipProvenance = 'pool' | 'manual';

/** Classifies a resolved chip for the sheet's plain-vs-removable-blue
 *  visual treatment (mirrors `poolPullLogic.ts`'s `classifyChipProvenance`
 *  for the wizard's core-setup chip strip — same rule, this module's own
 *  state shape). */
export function classifyRosterChip(taskId: string, mix: RosterMix): RosterChipProvenance {
  return mix.manualTaskIds.includes(taskId) ? 'manual' : 'pool';
}
