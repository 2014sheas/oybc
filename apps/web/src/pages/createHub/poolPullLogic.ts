import {
  resolvePoolPullAdditions,
  type Pool,
  type Task,
} from '@oybc/shared';

/**
 * poolPullLogic.ts — the surviving pure helpers of the retired P3
 * "PULL IN A POOL" wizard layer (Board Sources P5 cleanup,
 * docs/BOARD_SOURCES.md §Removals). The pull/untoggle/manual-bookkeeping/
 * provenance/chip-classification/pool-order functions were deleted with
 * the flat pool-mix wizard model they served — the sources-native
 * replacements live in `wizardSources.ts`. What remains here is used
 * OUTSIDE the wizard's step-2 model:
 *
 * - `applyCoreBoardDefaultPrefill` — the Board-settings page's defaults
 *   summary (resolving a `CoreBoardDefault` to counts/names). The wizard
 *   itself now prefills as sources + manual instead.
 * - `computeCoreFloorGate` — the Preview step's core Activate-button gate.
 *
 * Extracted-pure-function convention (no DOM/hook harness in this repo's
 * Vitest setup) unchanged.
 */

/** Result of folding a `CoreBoardDefault` into a resolved selection. */
export interface CoreBoardDefaultPrefillResult {
  selectedTaskIds: Set<string>;
  pulledPoolIds: string[];
}

/**
 * Union one pool's resolvable supply into a selection — internal helper
 * for `applyCoreBoardDefaultPrefill` (the last survivor of the retired
 * exported `applyPullPool`). No-ops for a missing/soft-deleted/
 * already-included pool.
 */
function unionPoolSupply(
  poolId: string,
  selectedTaskIds: Set<string>,
  pulledPoolIds: string[],
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): CoreBoardDefaultPrefillResult {
  const pool = poolsById[poolId];
  if (pool === undefined || pool.isDeleted || pulledPoolIds.includes(poolId)) {
    return { selectedTaskIds, pulledPoolIds };
  }
  const additions = resolvePoolPullAdditions(poolId, [], poolsById, tasksById);
  const nextPulled = [...pulledPoolIds, poolId];
  if (additions.length === 0) {
    return { selectedTaskIds, pulledPoolIds: nextPulled };
  }
  const nextSelected = new Set(selectedTaskIds);
  for (const id of additions) nextSelected.add(id);
  return { selectedTaskIds: nextSelected, pulledPoolIds: nextPulled };
}

/**
 * P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 6 "Core-board setup") — resolves a `CoreBoardDefault`'s
 * `corePoolIds` + `coreDefaultTaskIds` into a resolved selection +
 * resolvable pool-id list. Since Board Sources P4 the WIZARD no longer
 * consumes this (its prefill lands as source rows + manual); the
 * Board-settings page's per-timeframe defaults summary is the remaining
 * caller. `coreDefaultTaskIds` are unioned in afterward, filtered to ids
 * that resolve to a non-deleted `Task` (a stale/missing default is
 * silently skipped, never an error).
 */
export function applyCoreBoardDefaultPrefill(
  corePoolIds: string[],
  coreDefaultTaskIds: string[],
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): CoreBoardDefaultPrefillResult {
  let selectedTaskIds = new Set<string>();
  let pulledPoolIds: string[] = [];
  for (const poolId of corePoolIds) {
    const result = unionPoolSupply(poolId, selectedTaskIds, pulledPoolIds, poolsById, tasksById);
    selectedTaskIds = result.selectedTaskIds;
    pulledPoolIds = result.pulledPoolIds;
  }
  for (const taskId of coreDefaultTaskIds) {
    const task = tasksById[taskId];
    if (task === undefined || task.isDeleted) continue;
    selectedTaskIds.add(taskId);
  }
  return { selectedTaskIds, pulledPoolIds };
}

export interface CoreFloorGate {
  /** How many more tasks are needed to reach the floor. 0 when satisfied. */
  remaining: number;
  isSatisfied: boolean;
  /** "Add N more" — empty string when satisfied (nothing to render). */
  message: string;
}

/**
 * P5 — the core-board-setup fillable-floor gate math for the Preview
 * step's Activate-button gate. `required` must always be
 * `fillableCellCount(size, centerType)` (never a hardcoded constant) —
 * callers are responsible for passing the live value; this function only
 * owns the remaining/satisfied/message arithmetic.
 */
export function computeCoreFloorGate(selectedCount: number, required: number): CoreFloorGate {
  const remaining = Math.max(0, required - selectedCount);
  return {
    remaining,
    isSatisfied: remaining === 0,
    message: remaining > 0 ? `Add ${remaining} more` : '',
  };
}
