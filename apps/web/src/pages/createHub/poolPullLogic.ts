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

export interface CoreBoardDefaultPrefillResult {
  selectedTaskIds: Set<string>;
  pulledPoolIds: string[];
}

/**
 * P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 6 "Core-board setup") — resolves a `CoreBoardDefault`'s
 * `corePoolIds` + `coreDefaultTaskIds` into the wizard's initial
 * `selectedTaskIds` / `pulledPoolIds` for a fresh core-board-setup session.
 *
 * Folds `applyPullPool` across `corePoolIds` in local variables — this
 * does NOT call the wizard's `pullPool` callback in a loop, which would
 * read stale closure state on every iteration within the same render tick
 * and only end up applying the LAST pool. `coreDefaultTaskIds` are unioned
 * in afterward, in their own order, filtered to ids that resolve to a
 * non-deleted `Task` in `tasksById` (mirrors the `Pool.taskIds`
 * resolvable-at-read convention — a stale/missing default is silently
 * skipped, never an error).
 *
 * Callers must NOT feed this result's `selectedTaskIds` into
 * `manualTaskIds` — every id here is pool- or default-sourced, never
 * hand-added. `manualTaskIds` starts (and stays) empty for this prefill
 * path; that's the whole point of P5 replacing the legacy DefaultPool
 * prefill, which incorrectly treated the entire prefill as manual.
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
    const result = applyPullPool(
      poolId,
      selectedTaskIds,
      pulledPoolIds,
      new Set(),
      poolsById,
      tasksById,
    );
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

/**
 * P5 — derives the "Start every &lt;Timeframe&gt; board with 'X'"
 * checkbox's checked state. True iff `pulledPoolIds` and
 * `savedCorePoolIds` are BOTH non-empty and represent the SAME set
 * (order-insensitive). This is a point-in-time snapshot comparison, not a
 * live binding — the checkbox's `checked` prop should recompute this on
 * every render from the wizard's live `pulledPoolIds` plus the fetched
 * `CoreBoardDefault.corePoolIds` (defaulting to `[]` when no default
 * exists yet); nothing here is independently tracked as UI state.
 */
export function isCorePoolDefaultSaved(
  pulledPoolIds: string[],
  savedCorePoolIds: string[],
): boolean {
  if (pulledPoolIds.length === 0 || savedCorePoolIds.length === 0) return false;
  if (pulledPoolIds.length !== savedCorePoolIds.length) return false;
  const a = new Set(pulledPoolIds);
  const b = new Set(savedCorePoolIds);
  if (a.size !== b.size) return false;
  for (const id of a) {
    if (!b.has(id)) return false;
  }
  return true;
}

export interface CoreFloorGate {
  /** How many more tasks are needed to reach the floor. 0 when satisfied. */
  remaining: number;
  isSatisfied: boolean;
  /** "Add N more" — empty string when satisfied (nothing to render). */
  message: string;
}

/**
 * P5 — the core-board-setup fillable-floor gate math, shared between the
 * Tasks step's red count and the Preview step's Activate-button gate.
 * `required` must always be `fillableCellCount(size, centerType)` (never a
 * hardcoded constant) — callers are responsible for passing the live
 * value; this function only owns the remaining/satisfied/message
 * arithmetic. Copy is deliberately "Add N more" (isCore-specific),
 * distinct from the non-core wizard's "Pick N more".
 */
export function computeCoreFloorGate(selectedCount: number, required: number): CoreFloorGate {
  const remaining = Math.max(0, required - selectedCount);
  return {
    remaining,
    isSatisfied: remaining === 0,
    message: remaining > 0 ? `Add ${remaining} more` : '',
  };
}

/**
 * Web inline-editing port PR-1 (docs: CLAUDE.md §Board wizard "From a
 * board" picker's sibling section on the pool-first Tasks-step restructure)
 * — derives the pool's insertion-order array from the previous order plus
 * the NEW `selectedTaskIds` set, after ANY action that can add/remove
 * members (`toggleTaskSelection`, `pullPool`, `untogglePool`, the
 * template-mix / CoreBoardDefault prefill effects, `reset`).
 *
 * Rule: ids already in `prevOrder` that are STILL selected keep their
 * existing position (so a later inline rename — PR-2 — never reshuffles
 * the list); ids newly present in `nextSelectedIds` are appended in the
 * Set's iteration order (which is insertion order for every code path that
 * builds these Sets — `new Set()` + `.add()`, never reconstructed from an
 * unordered source). Ids no longer selected are dropped. Pure and
 * self-contained so it can run after every selection-changing action
 * without each call site re-deriving the same diff by hand.
 */
export function syncPoolOrder(prevOrder: string[], nextSelectedIds: Set<string>): string[] {
  const kept = prevOrder.filter((id) => nextSelectedIds.has(id));
  if (kept.length === nextSelectedIds.size) return kept;
  const keptSet = new Set(kept);
  const appended = Array.from(nextSelectedIds).filter((id) => !keptSet.has(id));
  return [...kept, ...appended];
}

export type ChipProvenanceKind = 'plain' | 'manual';

/**
 * P5 — classifies a single selected task id for the core-board-setup chip
 * strip: `'manual'` (hand-added this session — blue-tinted, removable ✕)
 * when the id is in `manualTaskIds`, otherwise `'plain'` (pool- or
 * `coreDefaultTaskIds`-sourced — no dismiss action). Pure passthrough over
 * `manualTaskIds.has(taskId)`, extracted as its own function purely so the
 * classification rule has one direct, testable name instead of being
 * inlined at every chip-rendering call site.
 */
export function classifyChipProvenance(
  taskId: string,
  manualTaskIds: Set<string>,
): ChipProvenanceKind {
  return manualTaskIds.has(taskId) ? 'manual' : 'plain';
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
