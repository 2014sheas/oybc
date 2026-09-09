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
  computeSourceCapacity,
  poolSourceSupplyById,
  resolveSourceAvailable,
  effectiveSourceMax,
  type BoardSource,
  type BoardSourceSupply,
  type Pool,
  type Task,
} from '@oybc/shared';

/**
 * Per-source display/supply cache entry — iOS `WizardSourceSupply`.
 * `rawSupplyTaskIds` is pre-exclude, pre-filter; `doneTaskIds` is empty
 * for pools.
 */
export interface WizardSourceSupply {
  displayName: string;
  rawSupplyTaskIds: string[];
  doneTaskIds: Set<string>;
}

export type SupplyInfoMap = Record<string, WizardSourceSupply>;

/** The algorithm-ready supplies: board `'todo'` filter applied by the
 *  platform (the P1 `BoardSourceSupply` contract); order = row order. */
export function algorithmSupplies(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
): BoardSourceSupply[] {
  return sources.map((source) => {
    const info = supplyInfo[source.sourceId];
    let raw = info?.rawSupplyTaskIds ?? [];
    if (source.kind === 'board' && source.filter === 'todo' && info) {
      raw = raw.filter((id) => !info.doneTaskIds.has(id));
    }
    return { source, supplyTaskIds: raw };
  });
}

/** One source's AVAILABLE count (post-exclude, post-filter) — the range
 *  slider's N, "of N", and the min clamp bound. */
export function availableCountForSource(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  sourceId: string,
): number {
  const supply = algorithmSupplies(sources, supplyInfo).find(
    (s) => s.source.sourceId === sourceId,
  );
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
): number {
  return computeSourceCapacity(
    algorithmSupplies(sources, supplyInfo),
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
): Set<string> {
  const union = new Set<string>();
  for (const supply of algorithmSupplies(sources, supplyInfo)) {
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

/** Re-clamp every source after a supply/exclude/filter change. */
export function clampAllSourceRanges(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  tasksRequired: number,
): BoardSource[] {
  return sources.map((source) =>
    clampSourceRange(
      source,
      availableCountForSource(sources, supplyInfo, source.sourceId),
      tasksRequired,
    ),
  );
}

/**
 * Library-sheet deselect of a source-supplied task: exclude it from
 * EVERY supplying source (the sheet has no per-source scope — the old
 * flat-removal global-suppress semantics; iOS `toggleTaskSelection`).
 * Returns a NEW sources array with mins re-clamped.
 */
export function excludeFromEverySupplier(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  taskId: string,
  tasksRequired: number,
): BoardSource[] {
  const next = sources.map((source) => {
    const raw = supplyInfo[source.sourceId]?.rawSupplyTaskIds ?? [];
    if (!raw.includes(taskId) || source.excludedTaskIds.includes(taskId)) {
      return source;
    }
    return { ...source, excludedTaskIds: [...source.excludedTaskIds, taskId] };
  });
  return clampAllSourceRanges(next, supplyInfo, tasksRequired);
}

/** Toggle one member's exclusion inside ONE source (the panel's ✕/UNDO). */
export function toggleExcludeInSource(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  sourceId: string,
  taskId: string,
  tasksRequired: number,
): BoardSource[] {
  const next = sources.map((source) => {
    if (source.sourceId !== sourceId) return source;
    const excluded = source.excludedTaskIds.includes(taskId)
      ? source.excludedTaskIds.filter((id) => id !== taskId)
      : [...source.excludedTaskIds, taskId];
    return { ...source, excludedTaskIds: excluded };
  });
  return clampAllSourceRanges(next, supplyInfo, tasksRequired);
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
