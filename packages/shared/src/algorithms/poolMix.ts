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
 * Wizard "PULL IN A POOL" action (P3) — computes the taskIds to ADD to the
 * wizard's flat `selectedTaskIds` when the user toggles a pool ON.
 *
 * Returns the pool's resolvable supply minus anything currently suppressed
 * by `removedTaskIds` — a removal persists across a fresh pull (the worked
 * example's "re-pull clears the removal" only happens via
 * `clearRemovalsForUntoggle` at UNTOGGLE time, never at pull time; see the
 * module docstring's worked example).
 *
 * Has a Swift twin: `PoolMix.resolvePoolPullAdditions` — keep in sync.
 *
 * @param poolId The pool being pulled in.
 * @param removedTaskIds The wizard's current removal bookkeeping.
 * @param poolsById Lookup for `poolId`. Missing or soft-deleted ⇒ no additions.
 * @param tasksById Lookup used to filter the pool's `taskIds` to resolvable tasks.
 * @returns Task ids to union into the selection, in the pool's own stored order.
 */
export function resolvePoolPullAdditions(
  poolId: string,
  removedTaskIds: string[],
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): string[] {
  const pool = poolsById[poolId];
  if (pool === undefined || pool.isDeleted) return [];
  const removedSet = new Set(removedTaskIds);
  return resolvablePoolSupply(pool, tasksById).filter((id) => !removedSet.has(id));
}

/**
 * Wizard "untoggle a pool" action (P3) — computes the taskIds to REMOVE
 * from the wizard's flat `selectedTaskIds` when the user toggles a pool
 * OFF. Per docs/POOLS_RECURRING.md §Data model "Union rule": untoggling
 * removes ONLY that pool's non-manual tasks that aren't ALSO supplied by
 * another currently-pulled pool. The manual layer is NEVER touched by a
 * pool toggle.
 *
 * Supply is checked STRUCTURALLY (raw `taskIds` membership, not filtered
 * for task-deletion) for the "still supplied elsewhere" check — matching
 * `clearRemovalsForUntoggle`'s "remaining supply" semantics — so a
 * soft-deleted remaining pool contributes no supply either.
 *
 * Has a Swift twin: `PoolMix.resolvePoolUntoggleRemovals` — keep in sync.
 *
 * @param poolId The pool being untoggled (pulled out).
 * @param remainingPoolIds `pulledPoolIds` with `poolId` already excluded.
 * @param manualTaskIds The wizard's current manual-layer bookkeeping —
 *   a manual task is never removed by a pool toggle.
 * @param poolsById Lookup for `poolId` and `remainingPoolIds`.
 * @param tasksById Lookup used to filter `poolId`'s own `taskIds` to
 *   resolvable tasks (the candidate removal set).
 * @returns Task ids to remove from the selection.
 */
export function resolvePoolUntoggleRemovals(
  poolId: string,
  remainingPoolIds: string[],
  manualTaskIds: string[],
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): string[] {
  const pool = poolsById[poolId];
  if (pool === undefined || pool.isDeleted) return [];
  const manualSet = new Set(manualTaskIds);
  const remainingSupply = new Set<string>();
  for (const otherId of remainingPoolIds) {
    const other = poolsById[otherId];
    if (other === undefined || other.isDeleted) continue;
    for (const taskId of other.taskIds) remainingSupply.add(taskId);
  }
  return resolvablePoolSupply(pool, tasksById).filter(
    (id) => !manualSet.has(id) && !remainingSupply.has(id),
  );
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

/**
 * Preserve-merge for the legacy template editor's Pool write-through
 * (docs/POOLS_RECURRING.md §Migration — "seedTaskIds end state").
 *
 * The legacy wizard hydrates its selection from `resolveMix`, whose
 * `resolvablePoolSupply` filters out soft-deleted tasks — so writing that
 * resolved selection STRAIGHT to `Pool.taskIds` would prune soft-deleted-
 * but-deliberately-preserved refs, breaking `Pool.taskIds`'s contract
 * ("Soft-deleted tasks are NOT auto-removed … the user's intent survives a
 * temporary delete/undo"; consumers filter at read time — a write must never
 * prune). This computes the write set that preserves them:
 *
 *   - An existing pool ref is KEPT when it is still in the selection (user
 *     kept it) OR is currently UNRESOLVABLE (soft-deleted / missing — it was
 *     never shown to the user, so it can't have been explicitly removed).
 *   - A resolvable ref the user dropped from the selection IS removed.
 *   - Newly-selected ids are appended in selection order.
 *
 * Existing pool order is preserved (dedup, existing first, additions last).
 * Mirrors the Pool-edit sheet's raw-list preservation semantics (which keeps
 * the raw `pool.taskIds` in state and only drops ids on explicit removal),
 * without needing the wizard to carry the raw list through selection state.
 *
 * Has a Swift twin: `apps/ios/OYBC/Helpers/PoolMix.swift`
 * (`mergeLegacyPoolTaskIds`) — keep them in sync.
 *
 * @param existingTaskIds The linked Pool's current raw `taskIds` (may include
 *   soft-deleted / unresolvable refs).
 * @param selectedTaskIds The wizard's post-edit resolved selection.
 * @param tasksById Lookup used to classify each existing ref as resolvable
 *   (present + not soft-deleted) or not.
 * @returns The merged `taskIds` to write — deduped, existing order first,
 *   then any new additions in selection order.
 */
export function mergeLegacyPoolTaskIds(
  existingTaskIds: string[],
  selectedTaskIds: string[],
  tasksById: Record<string, Task>,
): string[] {
  const selectedSet = new Set(selectedTaskIds);
  const result: string[] = [];
  const seen = new Set<string>();
  for (const taskId of existingTaskIds) {
    if (seen.has(taskId)) continue;
    const task = tasksById[taskId];
    const resolvable = task !== undefined && !task.isDeleted;
    if (selectedSet.has(taskId) || !resolvable) {
      result.push(taskId);
      seen.add(taskId);
    }
  }
  for (const taskId of selectedTaskIds) {
    if (seen.has(taskId)) continue;
    result.push(taskId);
    seen.add(taskId);
  }
  return result;
}

/**
 * Result of `summarizeSpawnProvenance` — the raw counts behind the
 * spawn-success provenance note (docs/POOLS_RECURRING.md §Surfaces item 7,
 * e.g. "Dealt 8 of 10 — 7 from the pool, 1 added today").
 */
export interface SpawnProvenanceSummary {
  /** Cells actually filled on the spawned board. */
  dealt: number;
  /** Size of the resolved mix the spawn drew from (`resolveMix(...).taskIds.length`). */
  mixSize: number;
  /** Of the dealt cells, how many came from a pool (mix minus manual-sourced). */
  poolSourcedCount: number;
  /** Of the dealt cells, how many came from the manual layer. */
  manualSourcedCount: number;
}

/**
 * Computes the pool-vs-manual breakdown of a freshly-dealt board's placed
 * tasks, for the spawn-success provenance note. Generic over ANY spawn
 * record shape (`PoolMixSource`) — including a "Repeat this board…" record,
 * which has zero pools and is 100% manual (see `buildRepeatBoardTemplateInput`
 * in `./recurringBoardTemplates`).
 *
 * @param spawnSource - The record's pool-mix fields (`poolIds`/
 *   `manualTaskIds`/`removedTaskIds`).
 * @param poolsById - Lookup used by `resolveMix` to size the full resolvable mix.
 * @param tasksById - Lookup used by `resolveMix`.
 * @param dealtTaskIds - The task ids actually placed on the spawned board
 *   (i.e. the board's live non-deleted BoardTask rows' `taskId`s) — may be a
 *   strict subset of the mix when the mix overfills the board (loose-fit).
 */
export function summarizeSpawnProvenance(
  spawnSource: PoolMixSource,
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
  dealtTaskIds: string[],
): SpawnProvenanceSummary {
  const mix = resolveMix(spawnSource, poolsById, tasksById);
  const manualSet = new Set(spawnSource.manualTaskIds ?? []);
  const manualSourcedCount = dealtTaskIds.filter((id) => manualSet.has(id)).length;
  return {
    dealt: dealtTaskIds.length,
    mixSize: mix.taskIds.length,
    poolSourcedCount: dealtTaskIds.length - manualSourcedCount,
    manualSourcedCount,
  };
}

/**
 * Formats the spawn-success provenance note copy, e.g.
 * `"Dealt 8 of 10 — 7 from the pool, 1 added today"`.
 *
 * Deliberate deviation from docs/POOLS_RECURRING.md's illustrative example
 * ("9 from defaults") — that wording is specific to the P5 CoreBoardDefault
 * feature. This note is generic to ANY freshly-spawned board, including a
 * "repeat this board" spawn that has no pool involvement at all (100%
 * manual) — "from defaults" would be nonsensical there, so this uses the
 * generic "from the pool" wording instead. "added today" is kept verbatim
 * (that phrasing is accurate generically).
 *
 * @param summary - From `summarizeSpawnProvenance`.
 */
export function formatSpawnProvenanceNote(summary: SpawnProvenanceSummary): string {
  const parts: string[] = [];
  if (summary.poolSourcedCount > 0) parts.push(`${summary.poolSourcedCount} from the pool`);
  if (summary.manualSourcedCount > 0) parts.push(`${summary.manualSourcedCount} added today`);
  const breakdown = parts.length > 0 ? ` — ${parts.join(', ')}` : '';
  return `Dealt ${summary.dealt} of ${summary.mixSize}${breakdown}`;
}

/**
 * `PoolSchema.name` is bounded to 120 chars (`z.string().min(1).max(120)`,
 * `schemas.ts`). Every site that MINTS a Pool by appending a fixed suffix
 * word to a source name (a `RecurringBoardTemplate.name` — itself bounded
 * to 120 — or a fixed timeframe label) must clamp the source FIRST, or the
 * appended result can exceed 120 and fail `PoolSchema` on the next device's
 * pull (review finding I1) — the doc never lands there, silently, since the
 * mint itself succeeds locally (no local Zod check on write).
 *
 * Used by all four mint sites, both platforms: the P1 migration
 * (`migrationV16.ts` / `MigrationV25Helpers.swift`, `" default"` /
 * `" pool"` suffixes) and the legacy-create wizard-persist mint
 * (`wizardPersist.ts` / `BoardWizardPersist.swift`, `" pool"` suffix). Has
 * a Swift twin: `PoolMix.swift`'s `clampMintedPoolName` — keep them in
 * sync.
 *
 * `.length` (JS) and `.utf16.count` (Swift) both measure UTF-16 code units,
 * the same unit `PoolSchema`'s `.max(120)` counts — so the two platforms
 * clamp the identical boundary. When that boundary would fall between a
 * surrogate pair (a non-BMP char — emoji, ZWJ sequences), we back off one
 * unit rather than emit a lone surrogate; both platforms do this identically,
 * so a non-BMP-heavy name mints byte-equal on web and iOS (review M-1).
 *
 * @param sourceName The un-suffixed source text (template name / timeframe label).
 * @param suffix     The word appended after a single space (e.g. `"pool"`, `"default"`).
 * @param maxLen     The schema's max length. Defaults to `PoolSchema`'s 120.
 * @returns `"<clamped sourceName> <suffix>"`, guaranteed `.length <= maxLen`
 *          and never ending in a split surrogate.
 */
export function clampMintedPoolName(
  sourceName: string,
  suffix: string,
  maxLen = 120,
): string {
  const suffixWithSpace = ` ${suffix}`;
  const maxSourceLen = Math.max(0, maxLen - suffixWithSpace.length);
  let clampedSource = sourceName;
  if (sourceName.length > maxSourceLen) {
    let end = maxSourceLen;
    // If the last kept unit is a high surrogate (0xD800–0xDBFF), its low
    // partner is being cut — drop the whole char instead of splitting it.
    if (end > 0) {
      const lastUnit = sourceName.charCodeAt(end - 1);
      if (lastUnit >= 0xd800 && lastUnit <= 0xdbff) end -= 1;
    }
    clampedSource = sourceName.slice(0, end);
  }
  return `${clampedSource}${suffixWithSpace}`;
}
