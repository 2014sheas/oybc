/**
 * boardSources.ts — Board Sources rework (docs/BOARD_SOURCES.md, P1).
 *
 * Pure functions for the sources-based board-assembly model: per-source
 * supply resolution (excludes), the capacity/gate math ("sum of maxes +
 * hand-added, deduped"), the min/max-respecting fill selection, and the
 * legacy-trio ⇄ sources conversions that keep P1 behavior-identical.
 *
 * No persistence; no platform code; no side effects. The PLATFORM resolves
 * each source's raw supply (a pool's resolvable `taskIds`; a board
 * instance's placed task ids with the `'todo'` filter already applied —
 * completion state is platform data this module never sees) and hands it
 * in as a `BoardSourceSupply`; everything from the exclude subtraction on
 * is shared and vector-pinned.
 *
 * **Selection semantics (normative — pinned by
 * `tests/fixtures/boardSourceVectors.json`, mirrored in XCTest):**
 *
 * - Ranges are **membership** constraints: for every source i,
 *   `min_i ≤ |board ∩ available_i| ≤ effectiveMax_i`. No pick is
 *   "attributed" to one source — a task supplied by two sources counts
 *   toward both memberships (and may satisfy two mins at once); a manual
 *   task that a source also supplies counts toward that source's cap.
 * - `max: null` is the "all" latch: `effectiveMax = availableCount`, so an
 *   untouched source tracks its live size.
 * - Mins are clamped, never errors: `target_i = min(min_i, available_i,
 *   effectiveMax_i, cellCount)`. A min the supply can't satisfy fills as
 *   far as it can — the capacity gate, not the fill, is what blocks
 *   creation.
 * - Fill order: mins first (sources in row order, random picks within the
 *   source), then the remaining cells at random from all remaining
 *   admissible candidates. Never underfills silently — a short result is
 *   an explicit `ok: false` the caller maps to its gate / `pool_too_small`
 *   skip.
 * - Behavior-identity for migrated shapes: every source at `[0, all]` with
 *   the flat legacy removals copied to each source's excludes yields
 *   exactly the old `resolveMix` candidate set, and an unconstrained fill
 *   is a uniform random subset — the pre-rework spawn distribution.
 *
 * Has a Swift twin: `apps/ios/OYBC/Helpers/BoardSources.swift` — ported
 * case-for-case, pinned by the same vector fixture
 * (`OYBCTests/BoardSourceVectorTests.swift`). Keep them in sync.
 */

import { fisherYatesShuffle } from '@oybc/bingo-core';
import type { BoardSource } from '../types/boardSource';
import type { Pool } from '../types/pool';
import type { Task } from '../types/task';

/**
 * One source plus its platform-resolved RAW supply (before excludes).
 *
 * - kind `'pool'`: the pool's resolvable task ids (present + non-deleted),
 *   in the pool's own stored order — `poolSourceSupplyById` builds this.
 * - kind `'board'`: the resolved instance's placed task ids, with the
 *   `'todo'` filter already applied by the platform (P2 wires this; a P1
 *   record can't contain board sources, and an unresolvable source simply
 *   passes `[]` — it contributes nothing, never blocks).
 */
export interface BoardSourceSupply {
  source: BoardSource;
  supplyTaskIds: string[];
}

/**
 * A source's AVAILABLE list: raw supply − `excludedTaskIds`, deduped,
 * order preserved. Stale-inert excludes (ids the supply doesn't contain)
 * subtract nothing — by design (docs/BOARD_SOURCES.md §Migration).
 */
export function resolveSourceAvailable(supply: BoardSourceSupply): string[] {
  const excluded = new Set(supply.source.excludedTaskIds);
  const seen = new Set<string>();
  const out: string[] = [];
  for (const id of supply.supplyTaskIds) {
    if (excluded.has(id) || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

/** `max: null` = the "all" latch → the live available count. */
export function effectiveSourceMax(
  source: BoardSource,
  availableCount: number,
): number {
  return source.max === null ? availableCount : Math.min(source.max, availableCount);
}

/** Result of {@link computeSourceCapacity}. */
export interface SourceCapacityResult {
  /** Distinct tasks that could possibly appear (manual ∪ all availables). */
  uniqueCandidateCount: number;
  /**
   * The design's header sum: Σ per-source effective max, plus the distinct
   * manual tasks **no source supplies** (a manual task inside a source
   * counts toward that source's membership cap, so counting it separately
   * would inflate the bound — the "membership cap binds manual-supplied
   * tasks too" rule).
   */
  cappedBound: number;
  /**
   * What the header/gate compares against `fillableCellCount`:
   * `min(uniqueCandidateCount, cappedBound)`. For all-`[0, all]` sources
   * this equals the old flat mix size (behavior-identity). With numeric
   * caps AND heavy cross-source overlap this is an upper-bound estimate
   * (exact feasibility is a matching problem) — the fill itself is the
   * final arbiter and never underfills.
   */
  capacity: number;
}

/**
 * The header/gate math (docs/BOARD_SOURCES.md §Selection step 3): "sum of
 * every source's max + hand-added, deduped by task".
 */
export function computeSourceCapacity(
  supplies: BoardSourceSupply[],
  manualTaskIds: string[],
): SourceCapacityResult {
  const unique = new Set<string>(manualTaskIds);
  const suppliedAnywhere = new Set<string>();
  let capSum = 0;
  for (const supply of supplies) {
    const available = resolveSourceAvailable(supply);
    capSum += effectiveSourceMax(supply.source, available.length);
    for (const id of available) {
      unique.add(id);
      suppliedAnywhere.add(id);
    }
  }
  const manualOutside = new Set(
    manualTaskIds.filter((id) => !suppliedAnywhere.has(id)),
  ).size;
  const cappedBound = capSum + manualOutside;
  return {
    uniqueCandidateCount: unique.size,
    cappedBound,
    capacity: Math.min(unique.size, cappedBound),
  };
}

export interface SelectBoardTasksArgs {
  supplies: BoardSourceSupply[];
  /** Hand-added layer — candidates with no range constraints of their own
   *  (but counting toward the membership cap of any source that also
   *  supplies them). Caller-curated; not deleted-filtered here (mirrors
   *  `resolveMix`'s manual-layer contract). */
  manualTaskIds: string[];
  /** Cells to fill — `fillableCellCount(size, center)`. */
  cellCount: number;
  /** Uniform `[0, 1)` RNG. Default `Math.random`; tests pass a seeded LCG
   *  (`makeSeededRng`) so vectors pin exact outputs on both platforms. */
  rng?: () => number;
}

export type SelectBoardTasksResult =
  | { ok: true; taskIds: string[] }
  | { ok: false; shortBy: number };

/**
 * Picks exactly `cellCount` task ids satisfying every source's membership
 * range (see the module docstring's normative semantics), or reports how
 * short the candidate pool ran. Never returns an underfilled `ok: true` —
 * boards are always exactly filled (standing invariant).
 */
export function selectBoardTasks(
  args: SelectBoardTasksArgs,
): SelectBoardTasksResult {
  const rng = args.rng ?? Math.random;
  const { supplies, manualTaskIds, cellCount } = args;

  // Per-source available lists + membership sets + effective caps.
  const availables = supplies.map(resolveSourceAvailable);
  const availableSets = availables.map((a) => new Set(a));
  const caps = supplies.map((s, i) => effectiveSourceMax(s.source, availables[i].length));
  const memberCounts = supplies.map(() => 0);

  // Candidate universe, first-seen order: manual, then sources in row order.
  const candidateSeen = new Set<string>();
  const candidates: string[] = [];
  for (const id of manualTaskIds) {
    if (candidateSeen.has(id)) continue;
    candidateSeen.add(id);
    candidates.push(id);
  }
  for (const available of availables) {
    for (const id of available) {
      if (candidateSeen.has(id)) continue;
      candidateSeen.add(id);
      candidates.push(id);
    }
  }

  const picked: string[] = [];
  const pickedSet = new Set<string>();

  const admissible = (id: string): boolean => {
    for (let i = 0; i < supplies.length; i++) {
      if (availableSets[i].has(id) && memberCounts[i] >= caps[i]) return false;
    }
    return true;
  };
  const pick = (id: string): void => {
    picked.push(id);
    pickedSet.add(id);
    for (let i = 0; i < supplies.length; i++) {
      if (availableSets[i].has(id)) memberCounts[i] += 1;
    }
  };

  // Phase A — satisfy mins, sources in row order. A task already picked
  // (via manual overlap or an earlier source) counts toward this source's
  // membership, so `target` may already be met without new picks.
  for (let i = 0; i < supplies.length; i++) {
    const target = Math.min(
      Math.max(0, supplies[i].source.min),
      availables[i].length,
      caps[i],
      cellCount,
    );
    if (memberCounts[i] >= target) continue;
    const shuffledOwn = fisherYatesShuffle(
      availables[i].filter((id) => !pickedSet.has(id)),
      rng,
    );
    for (const id of shuffledOwn) {
      if (memberCounts[i] >= target || picked.length >= cellCount) break;
      if (!admissible(id)) continue;
      pick(id);
    }
  }

  // Phase B — fill the remaining cells at random from every remaining
  // admissible candidate (manual and source-supplied alike).
  const shuffledRest = fisherYatesShuffle(
    candidates.filter((id) => !pickedSet.has(id)),
    rng,
  );
  for (const id of shuffledRest) {
    if (picked.length >= cellCount) break;
    if (!admissible(id)) continue;
    pick(id);
  }

  if (picked.length < cellCount) {
    return { ok: false, shortBy: cellCount - picked.length };
  }
  return { ok: true, taskIds: picked };
}

/**
 * Raw supply for a pool-kind source: the pool's own `taskIds`, filtered to
 * present + non-deleted tasks, order preserved. A missing or soft-deleted
 * pool supplies nothing (derived detachment — matches `resolveMix`).
 */
export function poolSourceSupplyById(
  sourceId: string,
  poolsById: Record<string, Pool>,
  tasksById: Record<string, Task>,
): string[] {
  const pool = poolsById[sourceId];
  if (pool === undefined || pool.isDeleted) return [];
  return pool.taskIds.filter((taskId) => {
    const task = tasksById[taskId];
    return task !== undefined && !task.isDeleted;
  });
}

/** The legacy-trio subset both conversions read/write. */
export interface LegacyMixFields {
  poolIds?: string[];
  removedTaskIds?: string[];
}

/**
 * Legacy trio → sources: each pulled pool becomes a `[0, all]` pool source
 * carrying the FULL flat `removedTaskIds` list as its excludes. Copying
 * the whole list to every source is semantically identical to the old
 * global suppression (an exclude the pool doesn't supply is inert) and
 * needs no pool lookups — see docs/BOARD_SOURCES.md §Migration.
 */
export function sourcesFromMixFields(record: LegacyMixFields): BoardSource[] {
  const removedTaskIds = record.removedTaskIds ?? [];
  return (record.poolIds ?? []).map((poolId) => ({
    sourceId: poolId,
    kind: 'pool' as const,
    min: 0,
    max: null,
    excludedTaskIds: [...removedTaskIds],
    filter: 'all' as const,
  }));
}

/**
 * Sources → legacy trio mirror, written alongside `sources` during P1 so
 * every pre-rework reader (roster health, provenance, an old client build)
 * keeps working — see docs/BOARD_SOURCES.md §Data model. Lossy by design:
 * ranges and board-kind sources have no legacy representation (board
 * sources are dropped; excludes union into the flat list). P2 retires the
 * trio to decode-compat and this mirror with it.
 */
export function mixFieldsFromSources(sources: BoardSource[]): {
  poolIds: string[];
  removedTaskIds: string[];
} {
  const poolIds: string[] = [];
  const removed = new Set<string>();
  for (const source of sources) {
    if (source.kind === 'pool' && !poolIds.includes(source.sourceId)) {
      poolIds.push(source.sourceId);
    }
    for (const id of source.excludedTaskIds) removed.add(id);
  }
  return { poolIds, removedTaskIds: Array.from(removed) };
}

/**
 * The canonical read path for any record that may or may not carry the
 * P1 `sources` stamp yet: the stamped array when present, else the legacy
 * trio mapped on the fly. Works forever for rows written by old clients
 * (mixed-version acceptance) — no data backfill required.
 */
export function sourcesForRecord(
  record: LegacyMixFields & { sources?: BoardSource[] },
): BoardSource[] {
  return record.sources ?? sourcesFromMixFields(record);
}
