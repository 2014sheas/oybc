/**
 * poolMix.ts — Task Pools + Recurring Boards Rework (P1)
 *
 * Pure functions resolving a `RecurringBoardTemplate`-shaped spawn record's
 * generalized task source into the concrete task-id mix a spawn deals from,
 * plus the supporting supply-tracking helpers the "pull a pool in / untoggle
 * a pool" UI (P2+) needs. No persistence; no platform code; no side effects.
 *
 * **Mix = (union(pools' resolvable tasks) − removedTaskIds) + manualTaskIds.**
 * Evaluation order is normative: removals subtract from the pool union
 * FIRST, then the manual layer adds — so a task id present in BOTH
 * `manualTaskIds` and `removedTaskIds` is IN the mix (manual wins; removals
 * only ever suppress pool-sourced supply). Deleted pools and deleted tasks
 * are skipped at resolution time (derived detachment — no cascade write, no
 * LWW race). Deterministic order: first-seen pool order (in `poolIds`
 * order, then within each pool's own `taskIds` order), followed by any
 * manual-only task ids in `manualTaskIds` order.
 *
 * **Removals semantics** (flat `string[]`, no per-pool attribution): a
 * removal entry suppresses that task from the pool union regardless of
 * which pool(s) supply it. Untoggling a pool (`clearRemovalsForUntoggle`)
 * clears exactly the removal entries whose task is no longer supplied by
 * any REMAINING pulled pool — removals for still-supplied tasks persist.
 * Removal entries for tasks not supplied by any pulled pool are
 * stale-inert: harmless, never an error, cleaned opportunistically on save.
 *
 * Has a Swift twin: `apps/ios/OYBC/Helpers/PoolMix.swift` (Task 3), ported
 * case-for-case including the worked-example test vectors. Keep them in
 * sync.
 *
 * Canonical design: docs/POOLS_RECURRING.md §Changed: the spawn record
 * (recurrence as board property) — the worked example there is the
 * required P1 unit-test vector set (`tests/algorithms/poolMix.test.ts`).
 */

import type { Pool } from '../types/pool';
import type { Task } from '../types/task';

/**
 * The subset of a spawn record's fields `resolveMix` /
 * `clearRemovalsForUntoggle` / `isLegacyShapedRecord` need. Matches
 * `RecurringBoardTemplate`'s additive P1 fields directly (all optional, so
 * a `RecurringBoardTemplate` — migrated or not — can be passed as-is).
 * Missing fields default to empty per-array, per the "legacy shape"
 * definition below.
 */
export interface PoolMixSource {
  poolIds?: string[];
  manualTaskIds?: string[];
  removedTaskIds?: string[];
}

/**
 * Result of `resolveMix`.
 */
export interface ResolveMixResult {
  /**
   * The resolved mix, deduplicated, in deterministic order: first-seen
   * pool order, then any manual-only ids in `manualTaskIds` order. This is
   * the array the spawn path hands to `buildSpawnPlacement`'s `poolTasks`
   * (after a task-id → `Task` lookup) exactly as `seedTaskIds` used to be.
   */
  taskIds: string[];
  /**
   * Per-pulled-pool resolvable supply — that pool's own `taskIds`, filtered
   * to non-deleted tasks, in the pool's own stored order. Keyed by pool id;
   * a pulled pool that is missing from `poolsById` or soft-deleted has NO
   * entry (not an empty-array entry) — it contributed nothing, matching
   * derived detachment. Powers provenance UI ("from Morning Kickstart") and
   * `clearRemovalsForUntoggle`'s sibling logic.
   */
  suppliedByPool: Record<string, string[]>;
}

/**
 * Resolvable, non-deleted supply for one pool: its own `taskIds`, filtered
 * to tasks present in `tasksById` and not soft-deleted. Order preserved.
 */
function resolvablePoolSupply(
  pool: Pool,
  tasksById: Record<string, Task>,
): string[] {
  return pool.taskIds.filter((taskId) => {
    const task = tasksById[taskId];
    return task !== undefined && !task.isDeleted;
  });
}

/**
 * Resolves a spawn record's `poolIds` / `manualTaskIds` / `removedTaskIds`
 * into the concrete mix per the normative formula (see module docstring).
 *
 * @param record - The record's pool-mix fields (a `RecurringBoardTemplate`
 *   may be passed directly — its additive fields match `PoolMixSource`).
 *   Missing arrays are treated as empty.
 * @param poolsById - Lookup for every id in `record.poolIds`. A missing or
 *   soft-deleted entry is skipped (derived detachment) — never an error.
 * @param tasksById - Lookup for filtering each pool's `taskIds` to
 *   currently-resolvable (non-deleted, present) tasks. NOT applied to
 *   `manualTaskIds` — the manual layer is caller-curated (the wizard/roster
 *   UI only lets a user pick live tasks) and passes through verbatim,
 *   mirroring `buildSpawnPlacement`'s "caller filters" contract.
 */
export function resolveMix(
  record: PoolMixSource,
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): ResolveMixResult {
  const poolIds = record.poolIds ?? [];
  const manualTaskIds = record.manualTaskIds ?? [];
  const removedTaskIds = record.removedTaskIds ?? [];
  const removedSet = new Set(removedTaskIds);
  const manualSet = new Set(manualTaskIds);

  // Build the pool union in first-seen order, and the per-pool supply map.
  const suppliedByPool: Record<string, string[]> = {};
  const unionOrder: string[] = [];
  const unionSeen = new Set<string>();

  for (const poolId of poolIds) {
    const pool = poolsById[poolId];
    if (pool === undefined || pool.isDeleted) continue;
    // A duplicate poolId in `poolIds` re-derives the same supply — harmless,
    // just overwrites the map entry with an identical value.
    const supply = resolvablePoolSupply(pool, tasksById);
    suppliedByPool[poolId] = supply;
    for (const taskId of supply) {
      if (!unionSeen.has(taskId)) {
        unionSeen.add(taskId);
        unionOrder.push(taskId);
      }
    }
  }

  // Subtract removals (unless the manual layer overrides — manual wins),
  // then append any manual-only ids not already present.
  const resultSeen = new Set<string>();
  const taskIds: string[] = [];

  for (const taskId of unionOrder) {
    if (removedSet.has(taskId) && !manualSet.has(taskId)) continue;
    taskIds.push(taskId);
    resultSeen.add(taskId);
  }
  for (const taskId of manualTaskIds) {
    if (resultSeen.has(taskId)) continue;
    taskIds.push(taskId);
    resultSeen.add(taskId);
  }

  return { taskIds, suppliedByPool };
}

/**
 * Computes the surviving `removedTaskIds` after the user untoggles (pulls
 * out) one pool. Clears exactly the removal entries whose task is no
 * longer supplied by any of the REMAINING pulled pools; removals for
 * still-supplied tasks persist untouched.
 *
 * Supply here is checked structurally — a remaining pool's raw `taskIds`
 * membership (not filtered by task-deletion) — since this is a
 * removal-bookkeeping concern, distinct from mix *resolution*
 * (`resolveMix`, which additionally filters deleted tasks for the actual
 * spawn mix). A soft-deleted remaining pool contributes no supply here
 * either, matching derived detachment.
 *
 * @param record - Only `poolIds` and `removedTaskIds` are read.
 * @param untoggledPoolId - The pool id the user just pulled out.
 * @param poolsById - Lookup for the remaining pools' `taskIds`.
 * @returns The new `removedTaskIds` array (a subset of the input).
 */
export function clearRemovalsForUntoggle(
  record: PoolMixSource,
  untoggledPoolId: string,
  poolsById: Record<string, Pool>,
): string[] {
  const remainingPoolIds = (record.poolIds ?? []).filter(
    (id) => id !== untoggledPoolId,
  );
  const remainingSupply = new Set<string>();
  for (const poolId of remainingPoolIds) {
    const pool = poolsById[poolId];
    if (pool === undefined || pool.isDeleted) continue;
    for (const taskId of pool.taskIds) remainingSupply.add(taskId);
  }
  return (record.removedTaskIds ?? []).filter((taskId) =>
    remainingSupply.has(taskId),
  );
}

/**
 * True when a spawn record is "legacy shaped" — at most one pool, no
 * manual additions, no removals. Covers BOTH:
 *
 *   - A genuinely un-migrated record (`poolIds`/`manualTaskIds`/
 *     `removedTaskIds` all absent, `seedTaskIds` still authoritative).
 *   - A migration- or legacy-create-minted record (`poolIds.length === 1`,
 *     `manualTaskIds: []`, `removedTaskIds: []`).
 *
 * This is the ONLY shape the legacy template editor's write-through may
 * mutate the linked Pool's `taskIds` for (docs/POOLS_RECURRING.md
 * §Migration — "seedTaskIds end state"). A richer shape (2+ pools, any
 * manual additions, or any removals) is NOT legacy-shaped — the
 * defensive write-through fallback flattens to `manualTaskIds` and clears
 * `poolIds`/`removedTaskIds` instead of touching a shared Pool.
 */
export function isLegacyShapedRecord(record: PoolMixSource): boolean {
  const poolCount = record.poolIds?.length ?? 0;
  const manualCount = record.manualTaskIds?.length ?? 0;
  const removedCount = record.removedTaskIds?.length ?? 0;
  return poolCount <= 1 && manualCount === 0 && removedCount === 0;
}
