/**
 * wizardSources.ts — Board Sources P4 (docs/BOARD_SOURCES.md). Pure
 * helpers for the wizard's sources-native state — the web port of the
 * testable core of iOS `BoardWizardViewModel+Sources.swift`. No React,
 * no Dexie: `useBoardWizard` owns the state and the async supply
 * fetches; everything here is a pure function over that state, so the
 * worked-example semantics can be unit-tested without rendering a hook
 * (the `poolPullLogic.ts` role, for the sources model).
 */

import {
  applyMemberRules,
  computeSourceCapacity,
  poolSourceSupplyById,
  availableSupplyIds,
  resolveSourceAvailable,
  effectiveSourceMax,
  withPartRule,
  type BoardSource,
  type BoardWindow,
  type CompoundChild,
  type ExpandedSupply,
  type Pool,
  type Task,
} from '@oybc/shared';

/**
 * §Member rules (B3, RC7) — the compound children a Split-up expansion can
 * name. The wizard passes its live `childrenByCompoundId`; a caller that
 * omits it gets NO expansion (every split rule reads as stale-inert), which
 * is exactly the pre-B3 behaviour.
 */
export type SupplyChildrenMap = Record<
  string,
  Pick<CompoundChild, 'childTaskId' | 'childIndex'>[]
>;

/** §Member rules (B3) — the id→task slice the expansion reads (`type` only). */
export type SupplyTasksMap = Record<string, Pick<Task, 'id' | 'type'>>;

/**
 * Per-source display/supply cache entry — iOS `WizardSourceSupply`.
 * `rawSupplyTaskIds` is pre-exclude, pre-filter; `doneTaskIds` is empty
 * for pools.
 */
export interface WizardSourceSupply {
  displayName: string;
  rawSupplyTaskIds: string[];
  doneTaskIds: Set<string>;
  /**
   * The source's data hasn't resolved yet — its name/counts are NOT
   * known, as opposed to a genuinely missing (deleted) source.
   *
   * Late-mutation audit (2026-09-16, shape B): an unresolved pool used
   * to render as "Deleted pool · 0 squares", which also drove capacity
   * to 0, lit the red "! Add N more" gate and DISABLED Next — then all
   * of it corrected on load. An empty map means "not known yet", never
   * "deleted". See `reference_late_mutation_bug_class`.
   */
  isPending?: boolean;
  /**
   * §Member rules (B3, RC4) — board sources only: each event-owning
   * COUNTING member's windowed count in the SOURCE board's window. Absent
   * for pools (a pool has no window of its own) and while a board supply is
   * still pending.
   */
  windowCountByTaskId?: Record<string, number>;
  /**
   * §Member rules (B3, RC5) — board sources only: the source board's own
   * window, for pro-rating an auto target against the board being built.
   */
  sourceWindow?: BoardWindow;
  /**
   * Board sources only — the source still exists but resolved to NO board
   * for the window being built (owner ruling 2026-09-24: a series with no
   * instance containing the new board's start, or an ended/sealed one-off).
   * It supplies nothing (capacity 0 from it) and its row subtitle reads
   * "No board for this window yet". Distinct from a dead source ("Deleted
   * board"), which leaves this unset. iOS twin: `WizardSourceSupply.noBoardForWindow`.
   */
  noBoardForWindow?: boolean;
}

export type SupplyInfoMap = Record<string, WizardSourceSupply>;

/**
 * The algorithm-ready supplies: the board `'todo'` filter applied by the
 * platform (the P1 `BoardSourceSupply` contract), each source's
 * `excludedTaskIds` subtracted, and — §Member rules (B3, RC7) — Split-up
 * members expanded into their non-excluded parts via `applyMemberRules`.
 * Order = row order.
 *
 * Excludes are applied BEFORE the expansion (the same order the persist
 * path's mint uses): excluding a split compound must remove its parts, and
 * a part is not named by the compound's own exclude entry. Downstream
 * `resolveSourceAvailable` calls stay correct — it is idempotent.
 *
 * @param sources - The pulled source rows, in row order.
 * @param supplyInfo - The live supply cache.
 * @param childrenByCompoundId - Compound id → its `compound_children` rows.
 *   Omitted = no expansion (every split rule stale-inert).
 * @param tasksById - Id → task (only `id`/`type` are read).
 * @returns One expanded supply per source, order preserved.
 */
export function algorithmSupplies(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): ExpandedSupply[] {
  const raw = sources.map((source) => {
    const info = supplyInfo[source.sourceId];
    const ids = availableSupplyIds(source, info?.rawSupplyTaskIds ?? [], info?.doneTaskIds);
    return { source, supplyTaskIds: resolveSourceAvailable({ source, supplyTaskIds: ids }) };
  });
  return applyMemberRules(raw, childrenByCompoundId, tasksById);
}

/** One source's AVAILABLE count (post-exclude, post-filter, post-Split-up
 *  expansion) — the range slider's N, "of N", and the min clamp bound. A
 *  split compound contributes its parts, so the count grows by
 *  `parts − 1 − excluded parts`. */
export function availableCountForSource(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  sourceId: string,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): number {
  return availableCountFromSupplies(
    algorithmSupplies(sources, supplyInfo, childrenByCompoundId, tasksById),
    sourceId,
  );
}

/**
 * One source's AVAILABLE count read off supplies that are ALREADY expanded —
 * the form every surface holding `controller.expandedSupplies` should use, so
 * a display can't silently fall back to the un-split count by omitting the
 * expansion arguments (the B3 review's Important #1).
 *
 * @param supplies - The Split-up-expanded supplies, row-ordered.
 * @param sourceId - The row to count.
 * @returns The available count, or 0 when the row isn't among `supplies`.
 */
export function availableCountFromSupplies(
  supplies: readonly ExpandedSupply[],
  sourceId: string,
): number {
  const supply = supplies.find((s) => s.source.sourceId === sourceId);
  return supply ? resolveSourceAvailable(supply).length : 0;
}

/** The header/gate capacity — replaces `selectedTaskIds.size` everywhere
 *  the step gates/counts (docs/BOARD_SOURCES.md §Selection step 3).
 *  Since the counter-family rework this is the HONEST number: a
 *  deterministic dry-run of the actual fill, counting a shared-counter
 *  family once and respecting cap overlap — computed before any
 *  preview/deal, and never more than the deal can deliver. */
export function sourceCapacity(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  manualTaskIds: Set<string>,
  counterFamilyByTaskId?: Record<string, string>,
  pinnedTaskId?: string,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): number {
  return computeSourceCapacity(
    algorithmSupplies(sources, supplyInfo, childrenByCompoundId, tasksById),
    Array.from(manualTaskIds),
    counterFamilyByTaskId,
    pinnedTaskId ?? undefined,
  ).capacity;
}

/**
 * Counter-family collisions visible in the wizard pool: family key →
 * member ids, for every family with ≥2 members among `taskIds`. Drives
 * the "shares a counter with 'X' · one per board" row hints (owner
 * directive 2026-09-08 — two goals on one counter never share a board).
 */
export function computeCounterClashes(
  taskIds: Iterable<string>,
  counterFamilyByTaskId: Record<string, string>,
  taskById: Record<string, Task>,
): Map<string, string> {
  const membersByFamily = new Map<string, string[]>();
  for (const id of taskIds) {
    const fam = counterFamilyByTaskId[id];
    if (fam === undefined) continue;
    const members = membersByFamily.get(fam);
    if (members === undefined) membersByFamily.set(fam, [id]);
    else if (!members.includes(id)) members.push(id);
  }
  const out = new Map<string, string>();
  for (const members of membersByFamily.values()) {
    if (members.length < 2) continue;
    for (const id of members) {
      const other = members.find((m) => m !== id);
      if (other === undefined) continue;
      const title = taskById[other]?.title || 'another task';
      out.set(id, title);
    }
  }
  return out;
}

/** The selection union: dedupe(every source's available ∪ manual). */
export function selectionUnion(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  manualTaskIds: Set<string>,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): Set<string> {
  const union = new Set<string>();
  for (const supply of algorithmSupplies(sources, supplyInfo, childrenByCompoundId, tasksById)) {
    for (const id of resolveSourceAvailable(supply)) union.add(id);
  }
  for (const id of manualTaskIds) union.add(id);
  return union;
}

/** Clamp one source's min to `min(available, tasksRequired)`; a numeric
 *  max never drops below min. Returns a NEW source (never mutates). */
export function clampSourceRange(
  source: BoardSource,
  availableCount: number,
  tasksRequired: number,
): BoardSource {
  const cap = Math.min(availableCount, tasksRequired);
  const min = Math.max(0, Math.min(source.min, cap));
  const max = source.max !== null ? Math.max(source.max, min) : null;
  if (min === source.min && max === source.max) return source;
  return { ...source, min, max };
}

/** Re-clamp every source after a supply/exclude/filter/split change. */
export function clampAllSourceRanges(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  tasksRequired: number,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): BoardSource[] {
  return sources.map((source) =>
    clampSourceRange(
      source,
      availableCountForSource(
        sources,
        supplyInfo,
        source.sourceId,
        childrenByCompoundId,
        tasksById,
      ),
      tasksRequired,
    ),
  );
}

/**
 * Library-sheet deselect of a source-supplied task: suppress it in EVERY
 * supplying source (the sheet has no per-source scope — the old flat-removal
 * global-suppress semantics; iOS `toggleTaskSelection`). Returns a NEW
 * sources array with mins re-clamped.
 *
 * Membership is tested against the EXPANDED supplies, and HOW the id is
 * suppressed depends on how it got there (§Member rules B3, review
 * Important #2):
 *
 * - a plain member → the source's `excludedTaskIds`, as before;
 * - a Split-up PART → an `excluded: true` PART RULE on its parent compound.
 *   The pre-expansion supply never contains a `childTaskId`, so the old
 *   raw-supply test wrote nothing at all for a part — and the selection
 *   recompute (which reads the expanded supplies) put the square straight
 *   back. That is a self-reverting control, the late-mutation shape this
 *   codebase bans.
 *
 * Refuses (leaves that source untouched) when the part is the LAST included
 * part of its compound — a split member always contributes a square. Callers
 * driving a user gesture should ask `canDeselectFromSources` FIRST and no-op
 * on `false`, so the selection is never optimistically dropped and restored.
 */
export function excludeFromEverySupplier(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  taskId: string,
  tasksRequired: number,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): BoardSource[] {
  const supplies = algorithmSupplies(sources, supplyInfo, childrenByCompoundId, tasksById);
  let next = sources;
  for (const supply of supplies) {
    if (!supply.supplyTaskIds.includes(taskId)) continue;
    const sourceId = supply.source.sourceId;
    const parentId = supply.partOf[taskId];
    if (parentId !== undefined) {
      const partIds = (childrenByCompoundId[parentId] ?? []).map((c) => c.childTaskId);
      const rule = next.find((s) => s.sourceId === sourceId);
      if (rule === undefined) continue;
      const included = partIds.filter(
        (id) => !(rule.memberRules?.[parentId]?.parts?.[id]?.excluded ?? false),
      );
      // Last included part — refuse (the expansion would ignore it anyway).
      if (included.length <= 1 && included.includes(taskId)) continue;
      next = next.map((s) =>
        s.sourceId === sourceId ? withPartRule(s, parentId, taskId, { excluded: true }) : s,
      );
      continue;
    }
    next = next.map((s) =>
      s.sourceId === sourceId && !s.excludedTaskIds.includes(taskId)
        ? { ...s, excludedTaskIds: [...s.excludedTaskIds, taskId] }
        : s,
    );
  }
  return clampAllSourceRanges(next, supplyInfo, tasksRequired, childrenByCompoundId, tasksById);
}

/** Toggle one member's exclusion inside ONE source (the panel's ✕/UNDO). */
export function toggleExcludeInSource(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  sourceId: string,
  taskId: string,
  tasksRequired: number,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): BoardSource[] {
  const next = sources.map((source) => {
    if (source.sourceId !== sourceId) return source;
    const excluded = source.excludedTaskIds.includes(taskId)
      ? source.excludedTaskIds.filter((id) => id !== taskId)
      : [...source.excludedTaskIds, taskId];
    return { ...source, excludedTaskIds: excluded };
  });
  return clampAllSourceRanges(next, supplyInfo, tasksRequired, childrenByCompoundId, tasksById);
}

/** Build a pool source's supply entry from live lookups. */
export function poolSupplyEntry(
  pool: Pool,
  tasksById: Record<string, Task>,
): WizardSourceSupply {
  return {
    displayName: pool.name,
    rawSupplyTaskIds: poolSourceSupplyById(pool.id, { [pool.id]: pool }, tasksById),
    doneTaskIds: new Set(),
  };
}

/** The frame-5b range line: "up to 7" / "3–5" / "4" / "not done · up to 2".
 *  Shared by the source row subtitle and the recurring Preview summary. */
export function sourceRangeLine(
  source: BoardSource,
  availableCount: number,
): string {
  const effMax = effectiveSourceMax(source, availableCount);
  let core: string;
  if (source.min === 0) core = `up to ${effMax}`;
  else if (source.min >= effMax) core = `${effMax}`;
  else core = `${source.min}–${effMax}`;
  if (source.kind === 'board' && source.filter === 'todo') {
    return `not done · ${core}`;
  }
  return core;
}

/** Whether a source's range is the default `[0, all]`. */
export function isDefaultRange(source: BoardSource): boolean {
  return source.min === 0 && source.max === null;
}


/**
 * Build the wizard's per-source supply cache.
 *
 * Pool entries resolve synchronously from the live `poolsById`; board
 * entries come from the hook's async fetch. The load-state distinction
 * is load-bearing (late-mutation audit, shape B): a source we simply
 * haven't read yet is marked `isPending` — NOT rendered as
 * "Deleted pool"/"Deleted board" with 0 squares, which also drove
 * capacity to 0, lit the shortfall gate and disabled Next until the read
 * landed. An empty map means "not known yet", never "deleted".
 */
export function buildSupplyInfoMap(
  sources: BoardSource[],
  poolsById: Record<string, Pool>,
  poolsLoaded: boolean,
  tasksById: Record<string, Task>,
  boardSupplyById: SupplyInfoMap,
): SupplyInfoMap {
  const info: SupplyInfoMap = {};
  for (const source of sources) {
    if (source.kind === 'pool') {
      const pool = poolsById[source.sourceId];
      if (pool && !pool.isDeleted) {
        info[source.sourceId] = poolSupplyEntry(pool, tasksById);
      } else if (!poolsLoaded) {
        info[source.sourceId] = {
          displayName: 'Loading…',
          rawSupplyTaskIds: [],
          doneTaskIds: new Set(),
          isPending: true,
        };
      } else {
        // Genuinely gone: keep the last-known name when we have it; a
        // blank row is never honest UI.
        info[source.sourceId] = {
          displayName: pool?.name || 'Deleted pool',
          rawSupplyTaskIds: [],
          doneTaskIds: new Set(),
        };
      }
    } else {
      info[source.sourceId] = boardSupplyById[source.sourceId] ?? {
        displayName: 'Loading…',
        rawSupplyTaskIds: [],
        doneTaskIds: new Set(),
        // The async fetch writes a real entry (or an explicit "Deleted
        // board") when it settles; until then this is unknown.
        isPending: true,
      };
    }
  }
  return info;
}
