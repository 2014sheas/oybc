import {
  clearRemovalsForUntoggle,
  resolvePoolPullAdditions,
  resolvePoolUntoggleRemovals,
  type Pool,
  type Task,
} from '@oybc/shared';

/**
 * P3 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 5 "Wizard step 2") — pure pool-pull / pool-untoggle /
 * manual-bookkeeping / provenance logic extracted from `useBoardWizard`'s
 * new "PULL IN A POOL" state updates.
 *
 * Extracted rather than left inline in the hook because this repo's Vitest
 * harness has no DOM/hook-rendering support (`environment: 'node'`; see
 * `wizardTimeframeSeed.test.ts`'s docstring for the established
 * precedent) — hook-internal bookkeeping is covered via extracted pure
 * functions instead of `renderHook`.
 *
 * All functions operate on plain Sets/arrays/maps mirroring the wizard's
 * `pulledPoolIds` / `manualTaskIds` / `removedTaskIds` / `selectedTaskIds`
 * state shapes directly — no React, no Dexie. They delegate the actual
 * mix-membership math to `@oybc/shared`'s `poolMix` functions (the
 * canonical, cross-platform-mirrored algorithm) and only own the
 * "how does this fold into the wizard's flat `selectedTaskIds` +
 * bookkeeping Sets" wiring.
 */

export interface PullPoolResult {
  selectedTaskIds: Set<string>;
  pulledPoolIds: string[];
}

/**
 * Wizard "PULL IN A POOL" toggle-ON. Unions the pool's resolvable,
 * not-currently-removed supply into `selectedTaskIds` and appends the pool
 * id to `pulledPoolIds`. No-ops (returns the SAME references, so a caller
 * can cheaply skip a re-render) when the pool is missing, soft-deleted, or
 * already pulled.
 */
export function applyPullPool(
  poolId: string,
  selectedTaskIds: Set<string>,
  pulledPoolIds: string[],
  removedTaskIds: Set<string>,
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): PullPoolResult {
  const pool = poolsById[poolId];
  if (pool === undefined || pool.isDeleted || pulledPoolIds.includes(poolId)) {
    return { selectedTaskIds, pulledPoolIds };
  }
  const additions = resolvePoolPullAdditions(
    poolId,
    Array.from(removedTaskIds),
    poolsById,
    tasksById,
  );
  const nextPulled = [...pulledPoolIds, poolId];
  if (additions.length === 0) {
    return { selectedTaskIds, pulledPoolIds: nextPulled };
  }
  const nextSelected = new Set(selectedTaskIds);
  for (const id of additions) nextSelected.add(id);
  return { selectedTaskIds: nextSelected, pulledPoolIds: nextPulled };
}

export interface UntogglePoolResult {
  selectedTaskIds: Set<string>;
  pulledPoolIds: string[];
  removedTaskIds: Set<string>;
  /** The ids actually dropped from `selectedTaskIds`. Callers use this to
   *  also clear a matching `centerTaskId` and purge `pendingTasks` — the
   *  same cleanup `toggleTaskSelection` already does for a single
   *  deselect, just fanned out over every id this untoggle removed. */
  removedIds: string[];
}

/**
 * Wizard "PULL IN A POOL" toggle-OFF. Removes only the untoggled pool's
 * non-manual tasks that aren't ALSO supplied by a REMAINING pulled pool,
 * clears the now-stale-inert removal bookkeeping for tasks no longer
 * supplied by anything remaining, and drops the pool id. The manual layer
 * is never touched by a pool toggle (see `@oybc/shared`'s
 * `resolvePoolUntoggleRemovals` docstring for the full contract).
 */
export function applyUntogglePool(
  poolId: string,
  selectedTaskIds: Set<string>,
  pulledPoolIds: string[],
  manualTaskIds: Set<string>,
  removedTaskIds: Set<string>,
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): UntogglePoolResult {
  const remainingPoolIds = pulledPoolIds.filter((id) => id !== poolId);
  const removals = resolvePoolUntoggleRemovals(
    poolId,
    remainingPoolIds,
    Array.from(manualTaskIds),
    poolsById,
    tasksById,
  );
  const nextSelected = new Set(selectedTaskIds);
  for (const id of removals) nextSelected.delete(id);
  const nextRemoved = new Set(
    clearRemovalsForUntoggle(
      { poolIds: pulledPoolIds, removedTaskIds: Array.from(removedTaskIds) },
      poolId,
      poolsById,
    ),
  );
  return {
    selectedTaskIds: nextSelected,
    pulledPoolIds: remainingPoolIds,
    removedTaskIds: nextRemoved,
    removedIds: removals,
  };
}

export interface ManualBookkeepingResult {
  manualTaskIds: Set<string>;
  removedTaskIds: Set<string>;
}

/**
 * `toggleTaskSelection` SELECT-side bookkeeping: the task becomes
 * hand-picked. Also drops any stale `removedTaskIds` entry for it — pure
 * hygiene, since `resolveMix`'s "manual wins" rule already tolerates a
 * task id present in both sets.
 */
export function applyManualBookkeepingOnSelect(
  taskId: string,
  manualTaskIds: Set<string>,
  removedTaskIds: Set<string>,
): ManualBookkeepingResult {
  const nextManual = new Set(manualTaskIds);
  nextManual.add(taskId);
  if (!removedTaskIds.has(taskId)) {
    return { manualTaskIds: nextManual, removedTaskIds };
  }
  const nextRemoved = new Set(removedTaskIds);
  nextRemoved.delete(taskId);
  return { manualTaskIds: nextManual, removedTaskIds: nextRemoved };
}

/**
 * `toggleTaskSelection` DESELECT-side bookkeeping: the task is no longer
 * hand-picked. If it's still in the resolvable supply of any currently-
 * pulled (non-deleted) pool, record it as an explicit removal — so a
 * later pull of a DIFFERENT overlapping pool doesn't silently resurrect
 * it, and so a future pool untoggle's "still supplied elsewhere" check
 * sees it. A task not currently supplied by any pulled pool needs no
 * removal entry — deselecting it is already fully expressed by dropping
 * it from `selectedTaskIds`.
 */
export function applyManualBookkeepingOnDeselect(
  taskId: string,
  manualTaskIds: Set<string>,
  removedTaskIds: Set<string>,
  pulledPoolIds: string[],
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): ManualBookkeepingResult {
  const nextManual = new Set(manualTaskIds);
  nextManual.delete(taskId);
  const task = tasksById[taskId];
  const suppliedByAPulledPool =
    task !== undefined &&
    !task.isDeleted &&
    pulledPoolIds.some((poolId) => {
      const pool = poolsById[poolId];
      return pool !== undefined && !pool.isDeleted && pool.taskIds.includes(taskId);
    });
  if (!suppliedByAPulledPool) {
    return { manualTaskIds: nextManual, removedTaskIds };
  }
  const nextRemoved = new Set(removedTaskIds);
  nextRemoved.add(taskId);
  return { manualTaskIds: nextManual, removedTaskIds: nextRemoved };
}

/**
 * Provenance label for every currently-selected task — the Tasks-step row
 * subtitle ("from Morning Kickstart" / "added by hand"). Manual wins;
 * otherwise the FIRST pulled pool (in pull order) whose resolvable supply
 * includes the task; falls back to "added by hand" defensively (should
 * only trigger for edge-case bookkeeping gaps — e.g. a one-off board's
 * DefaultPool prefill, which has no pool-mix concept to attribute to —
 * never in ordinary pull/untoggle/manual steady state).
 *
 * Only entries for ids in `selectedTaskIds` are populated — callers
 * should look up by id and treat a missing entry as "not selected, no
 * provenance to show".
 */
export function deriveTaskProvenance(
  selectedTaskIds: Set<string>,
  manualTaskIds: Set<string>,
  pulledPoolIds: string[],
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): Map<string, string> {
  const provenance = new Map<string, string>();
  for (const taskId of selectedTaskIds) {
    if (manualTaskIds.has(taskId)) {
      provenance.set(taskId, 'added by hand');
      continue;
    }
    const task = tasksById[taskId];
    let label: string | null = null;
    if (task !== undefined && !task.isDeleted) {
      for (const poolId of pulledPoolIds) {
        const pool = poolsById[poolId];
        if (pool === undefined || pool.isDeleted) continue;
        if (pool.taskIds.includes(taskId)) {
          label = `from ${pool.name}`;
          break;
        }
      }
    }
    provenance.set(taskId, label ?? 'added by hand');
  }
  return provenance;
}
