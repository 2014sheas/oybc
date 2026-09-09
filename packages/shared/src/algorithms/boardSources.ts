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
 * - **Counter-family exclusivity** (owner directive 2026-09-08): at most
 *   ONE member of a shared-counter family (`sharedCounterId` root + its
 *   derived versions) lands on a board — two squares ticking together at
 *   different goals makes no sense. Priority when a family collides:
 *   pinned CHOSEN center > hand-added > covering-an-unmet-min > the draw
 *   (see `counterFamilyByTaskId` / `pinnedTaskId`).
 * - **The gate never overpromises**: `computeSourceCapacity`'s `capacity`
 *   is a deterministic DRY-RUN of this same fill (uncapped), and a short
 *   randomized deal retries in the dry-run's deterministic order — whose
 *   bounded pick is a prefix of the dry-run — so gate-passed ⇒ the board
 *   fills, even under pathological cap overlap.
 *
 * Has a Swift twin: `apps/ios/OYBC/Helpers/BoardSources.swift` — ported
 * case-for-case, pinned by the same vector fixture
 * (`OYBCTests/BoardSourceVectorTests.swift`). Keep them in sync.
 */

import { fisherYatesShuffle } from '@oybc/bingo-core';
import { TaskType } from '../constants/enums';
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
  /** Distinct placeable things (manual ∪ all availables), counting a
   *  shared-counter family ONCE — two goals on one counter can only ever
   *  yield one square. */
  uniqueCandidateCount: number;
  /**
   * The design's header sum: Σ per-source effective max, plus the distinct
   * manual tasks **no source supplies** (a manual task inside a source
   * counts toward that source's membership cap, so counting it separately
   * would inflate the bound — the "membership cap binds manual-supplied
   * tasks too" rule). Informational; `capacity` is the honest number.
   */
  cappedBound: number;
  /**
   * What the header/gate compares against `fillableCellCount`: the size
   * of a deterministic DRY-RUN of the actual fill (uncapped, unshuffled),
   * honoring source caps AND counter-family exclusivity. Always ≤
   * `min(uniqueCandidateCount, cappedBound)`; equal to it for every
   * non-pathological shape (and exactly the old flat mix size for
   * all-`[0, all]` sources — behavior-identity). Because a short
   * randomized deal retries in this same deterministic order,
   * gate-passed ⇒ the board fills.
   */
  capacity: number;
}

/**
 * The header/gate math (docs/BOARD_SOURCES.md §Selection step 3): "sum of
 * every source's max + hand-added, deduped by task" — with `capacity`
 * computed as the achievable dry-run size (see the field doc).
 */
export function computeSourceCapacity(
  supplies: BoardSourceSupply[],
  manualTaskIds: string[],
  counterFamilyByTaskId?: Record<string, string>,
  pinnedTaskId?: string,
): SourceCapacityResult {
  const familyKey = (id: string): string => counterFamilyByTaskId?.[id] ?? id;
  const unique = new Set<string>(manualTaskIds.map(familyKey));
  const suppliedAnywhere = new Set<string>();
  let capSum = 0;
  for (const supply of supplies) {
    const available = resolveSourceAvailable(supply);
    capSum += effectiveSourceMax(supply.source, available.length);
    for (const id of available) {
      unique.add(familyKey(id));
      suppliedAnywhere.add(id);
    }
  }
  const manualOutside = new Set(
    manualTaskIds.filter((id) => !suppliedAnywhere.has(id)).map(familyKey),
  ).size;
  const cappedBound = capSum + manualOutside;
  return {
    uniqueCandidateCount: unique.size,
    cappedBound,
    capacity: computeAchievablePoolSize({
      supplies,
      manualTaskIds,
      counterFamilyByTaskId,
      pinnedTaskId,
    }).size,
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
  /**
   * Whether picks are shuffled (the template's `isRandomized`). Default
   * true. When false the fill is fully deterministic in candidate order —
   * for `[0, all]` shapes this reproduces the pre-sources
   * `resolveMix`-order first-N slice exactly (same subset when
   * overfilled, same order), preserving the `isRandomized: false`
   * determinism contract `placeBoard` documents for its callers.
   */
  randomize?: boolean;
  /** Uniform `[0, 1)` RNG. Default `Math.random`; tests pass a seeded LCG
   *  (`makeSeededRng`) so vectors pin exact outputs on both platforms. */
  rng?: () => number;
  /**
   * Counter-family exclusivity (owner directive 2026-09-08): task id →
   * family key (`sharedCounterId ?? id`, counting tasks only — build via
   * `buildCounterFamilyMap`). At most one member of a family is ever
   * picked. Collision priority: the pinned CHOSEN center's mates are
   * pruned outright; a family with both hand-added and source-only
   * members prunes the source-only ones (explicit intent wins); remaining
   * ties resolve at draw time — Phase A reaches min-covering members
   * first, so "covers an unmet min" beats a plain draw naturally. Absent
   * map (or absent id) = unconstrained.
   */
  counterFamilyByTaskId?: Record<string, string>;
  /**
   * The CHOSEN center's task id, when the caller intends to pin it. Its
   * counter-family mates are pruned from the universe so the caller-side
   * center swap can never create a family violation. The pin itself is
   * NOT force-picked here — `buildWizardPlacement`'s swap owns that.
   */
  pinnedTaskId?: string;
}

export type SelectBoardTasksResult =
  | { ok: true; taskIds: string[] }
  | { ok: false; shortBy: number };

/**
 * Picks exactly `cellCount` task ids satisfying every source's membership
 * range AND counter-family exclusivity (see the module docstring), or
 * reports how short the candidate pool ran. Never returns an underfilled
 * `ok: true` — boards are always exactly filled (standing invariant).
 *
 * A short RANDOMIZED run retries once in deterministic candidate order —
 * the same order `computeSourceCapacity`'s dry-run counts — whose bounded
 * pick is a prefix of that dry-run. So a gate that passed on `capacity`
 * can never see this fail: an unlucky shuffle under pathological cap
 * overlap costs that deal its variety, never its board.
 */
export function selectBoardTasks(
  args: SelectBoardTasksArgs,
): SelectBoardTasksResult {
  const randomize = args.randomize ?? true;
  const first = runSelection(args, randomize);
  if (first.length >= args.cellCount) {
    return { ok: true, taskIds: first.slice(0, args.cellCount) };
  }
  const fallback = randomize ? runSelection(args, false) : first;
  if (fallback.length >= args.cellCount) {
    return { ok: true, taskIds: fallback.slice(0, args.cellCount) };
  }
  return { ok: false, shortBy: args.cellCount - fallback.length };
}

/** Result of {@link computeAchievablePoolSize}. */
export interface AchievablePoolSizeResult {
  /** How many squares this pool can ACTUALLY yield. */
  size: number;
  /** The dry-run's picks, in deterministic order (diagnostics/tests). */
  taskIds: string[];
}

/**
 * The honest pool size: a deterministic, uncapped dry-run of the exact
 * fill `selectBoardTasks` performs — source caps, mins, and
 * counter-family exclusivity all applied. This is what the wizard header,
 * the Step-2 gate, and the Preview SQUARES count show, computed BEFORE
 * any preview/deal.
 */
export function computeAchievablePoolSize(
  args: Omit<SelectBoardTasksArgs, 'cellCount' | 'randomize' | 'rng'>,
): AchievablePoolSizeResult {
  const taskIds = runSelection(
    { ...args, cellCount: Number.MAX_SAFE_INTEGER },
    false,
  );
  return { size: taskIds.length, taskIds };
}

/** The shared fill core — one code path for the deal, its deterministic
 *  retry, and the capacity dry-run (the alignment guarantee). */
function runSelection(
  args: Omit<SelectBoardTasksArgs, 'randomize'>,
  randomize: boolean,
): string[] {
  const rng = args.rng ?? Math.random;
  const { supplies, manualTaskIds, cellCount, counterFamilyByTaskId, pinnedTaskId } = args;
  const order = (ids: string[]): string[] =>
    randomize ? fisherYatesShuffle(ids, rng) : ids;

  // Per-source available lists + membership sets + effective caps.
  const availables = supplies.map(resolveSourceAvailable);
  const availableSets = availables.map((a) => new Set(a));
  const caps = supplies.map((s, i) => effectiveSourceMax(s.source, availables[i].length));
  const memberCounts = supplies.map(() => 0);

  // Candidate universe, first-seen order: sources in row order, then any
  // manual-only ids appended — the SAME deterministic order `resolveMix`
  // produced (pool union first, manual extras last), so the
  // `randomize: false` path slices the identical first-N the old spawn
  // did. (Membership caps are set-based, so candidate position never
  // affects WHICH source a pick counts against — only deterministic
  // ordering.)
  const candidateSeen = new Set<string>();
  const candidates: string[] = [];
  for (const available of availables) {
    for (const id of available) {
      if (candidateSeen.has(id)) continue;
      candidateSeen.add(id);
      candidates.push(id);
    }
  }
  for (const id of manualTaskIds) {
    if (candidateSeen.has(id)) continue;
    candidateSeen.add(id);
    candidates.push(id);
  }

  const picked: string[] = [];
  const pickedSet = new Set<string>();

  // Counter-family exclusivity — priority pruning up front, then a
  // runtime one-per-family guard for whatever the pruning left tied.
  const familyOf = (id: string): string | undefined => counterFamilyByTaskId?.[id];
  const blocked = new Set<string>();
  if (counterFamilyByTaskId !== undefined) {
    const membersByFamily = new Map<string, string[]>();
    for (const id of candidates) {
      const fam = familyOf(id);
      if (fam === undefined) continue;
      const members = membersByFamily.get(fam);
      if (members === undefined) membersByFamily.set(fam, [id]);
      else members.push(id);
    }
    const manualSet = new Set(manualTaskIds);
    const pinnedFamily = pinnedTaskId !== undefined ? familyOf(pinnedTaskId) : undefined;
    for (const [fam, members] of membersByFamily) {
      if (fam === pinnedFamily) {
        // The pinned CHOSEN center wins its family outright — mates are
        // pruned so the caller-side center swap can't collide.
        for (const id of members) {
          if (id !== pinnedTaskId) blocked.add(id);
        }
        continue;
      }
      if (members.length < 2) continue;
      // Hand-added beats source-supplied; ties (all hand-added, or all
      // source-only) fall through to the runtime guard = the draw.
      const handAdded = members.filter((id) => manualSet.has(id));
      if (handAdded.length > 0 && handAdded.length < members.length) {
        for (const id of members) {
          if (!manualSet.has(id)) blocked.add(id);
        }
      }
    }
  }
  const pickedFamilies = new Set<string>();

  const admissible = (id: string): boolean => {
    if (blocked.has(id)) return false;
    const fam = familyOf(id);
    if (fam !== undefined && pickedFamilies.has(fam)) return false;
    for (let i = 0; i < supplies.length; i++) {
      if (availableSets[i].has(id) && memberCounts[i] >= caps[i]) return false;
    }
    return true;
  };
  const pick = (id: string): void => {
    picked.push(id);
    pickedSet.add(id);
    const fam = familyOf(id);
    if (fam !== undefined) pickedFamilies.add(fam);
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
    const shuffledOwn = order(availables[i].filter((id) => !pickedSet.has(id)));
    for (const id of shuffledOwn) {
      if (memberCounts[i] >= target || picked.length >= cellCount) break;
      if (!admissible(id)) continue;
      pick(id);
    }
  }

  // Phase B — fill the remaining cells from every remaining admissible
  // candidate (manual and source-supplied alike): at random when
  // randomized, in candidate order when not.
  const shuffledRest = order(candidates.filter((id) => !pickedSet.has(id)));
  for (const id of shuffledRest) {
    if (picked.length >= cellCount) break;
    if (!admissible(id)) continue;
    pick(id);
  }

  return picked;
}

/**
 * Task id → counter-family key for {@link selectBoardTasks} /
 * {@link computeSourceCapacity}: counting tasks map to
 * `sharedCounterId ?? id` (a root and every version derived from it share
 * one family); other types carry no family constraint and get no entry.
 */
export function buildCounterFamilyMap(
  tasks: Iterable<Task>,
): Record<string, string> {
  const map: Record<string, string> = {};
  for (const task of tasks) {
    if (task.type !== TaskType.COUNTING) continue;
    map[task.id] = task.sharedCounterId ?? task.id;
  }
  return map;
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
