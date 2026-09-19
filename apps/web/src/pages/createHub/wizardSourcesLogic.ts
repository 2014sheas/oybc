/**
 * wizardSourcesLogic.ts — the pure transitions behind `useWizardSources`'s
 * actions (Board Sources P4 / §Member rules B3).
 *
 * `wizardSources.ts` holds the *queries* over the sources model (supplies,
 * available counts, capacity, the union); this module holds the *transitions*
 * — "what does the sources array look like after the user pulled a pool /
 * dragged a range handle / flipped a done-filter". Splitting them out is what
 * makes the nine source actions unit-testable: the Vitest harness in this repo
 * is `environment: 'node'` with no hook renderer, so a `useCallback` closure
 * can only be covered by testing the function it delegates to.
 *
 * Every function here is pure and returns a NEW value (never mutates its
 * input), so a hook can use it inside a functional `setState` updater.
 */

import type { BoardSource, BoardSourceFilter, BoardSourceKind } from '@oybc/shared';
import type { BoardSourceSupplyInfo } from '../../db/operations/boardSources';
import {
  availableCountForSource,
  clampAllSourceRanges,
  clampSourceRange,
  type SupplyChildrenMap,
  type SupplyInfoMap,
  type SupplyTasksMap,
  type WizardSourceSupply,
} from './wizardSources';

/**
 * Append a freshly-pulled source row with the default `[0, all]` range and
 * the "All squares" filter. A no-op (same array identity) when `sourceId` is
 * already pulled — the sheet's tap on an already-pulled row must not
 * duplicate it or reset its range.
 *
 * @param sources - The current source rows, in row order.
 * @param sourceId - `Pool.id` or `Board.id` being pulled.
 * @param kind - Which of the two the id names.
 * @returns The next rows (input array when already pulled).
 */
export function appendSource(
  sources: BoardSource[],
  sourceId: string,
  kind: BoardSourceKind,
): BoardSource[] {
  if (sources.some((source) => source.sourceId === sourceId)) return sources;
  return [
    ...sources,
    { sourceId, kind, min: 0, max: null, excludedTaskIds: [], filter: 'all' },
  ];
}

/**
 * Drop one source row (the row's ✕ / a sheet un-toggle). The saved Pool /
 * Board itself is untouched — only this board's pull of it.
 *
 * @param sources - The current source rows.
 * @param sourceId - The row to drop.
 * @returns The next rows.
 */
export function removeSourceById(sources: BoardSource[], sourceId: string): BoardSource[] {
  return sources.filter((source) => source.sourceId !== sourceId);
}

/**
 * Set one source's range from the slider. `max: null` is the "all" latch.
 * The result is re-clamped through {@link clampSourceRange} (defense in depth
 * — the slider bounds already cap `min` at `min(available, tasksRequired)`).
 *
 * @param sources - The current source rows.
 * @param supplyInfo - The live supply cache.
 * @param sourceId - The row being ranged.
 * @param min - Requested range minimum.
 * @param max - Requested range maximum, or `null` for "all".
 * @param tasksRequired - The board's fillable cell count.
 * @param childrenByCompoundId - Compound children, for the Split-up expansion.
 * @param tasksById - Id → task, for the Split-up expansion.
 * @returns The next rows.
 */
export function withSourceRange(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  sourceId: string,
  min: number,
  max: number | null,
  tasksRequired: number,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): BoardSource[] {
  return sources.map((source) => {
    if (source.sourceId !== sourceId) return source;
    return clampSourceRange(
      { ...source, min, max },
      availableCountForSource(sources, supplyInfo, sourceId, childrenByCompoundId, tasksById),
      tasksRequired,
    );
  });
}

/**
 * "Use all" — reset one source's range to the default `[0, all]`.
 *
 * @param sources - The current source rows.
 * @param sourceId - The row to reset.
 * @returns The next rows.
 */
export function withResetSourceRange(sources: BoardSource[], sourceId: string): BoardSource[] {
  return sources.map((source) =>
    source.sourceId === sourceId ? { ...source, min: 0, max: null } : source,
  );
}

/**
 * Flip a BOARD source's done-filter (pool rows carry the field but ignore
 * it, so a pool row is left alone). Narrowing to "Not done yet" shrinks the
 * available count, so every row is re-clamped afterwards.
 *
 * @param sources - The current source rows.
 * @param supplyInfo - The live supply cache.
 * @param sourceId - The row being filtered.
 * @param filter - The new filter.
 * @param tasksRequired - The board's fillable cell count.
 * @param childrenByCompoundId - Compound children, for the Split-up expansion.
 * @param tasksById - Id → task, for the Split-up expansion.
 * @returns The next rows, re-clamped.
 */
export function withSourceFilter(
  sources: BoardSource[],
  supplyInfo: SupplyInfoMap,
  sourceId: string,
  filter: BoardSourceFilter,
  tasksRequired: number,
  childrenByCompoundId: SupplyChildrenMap = {},
  tasksById: SupplyTasksMap = {},
): BoardSource[] {
  const next = sources.map((source) =>
    source.sourceId === sourceId && source.kind === 'board' ? { ...source, filter } : source,
  );
  return clampAllSourceRanges(next, supplyInfo, tasksRequired, childrenByCompoundId, tasksById);
}

/**
 * Add-or-remove one id in a `Set` immutably (the expanded-row toggle).
 *
 * @param set - The current set.
 * @param id - The id to flip.
 * @returns A new set with `id` flipped.
 */
export function toggleIdInSet(set: ReadonlySet<string>, id: string): Set<string> {
  const next = new Set(set);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}

/**
 * The selected ids a sources transition DROPS — the ones whose follow-on
 * state (center mark, pending payload, staged edit) must be purged.
 *
 * @param selected - The current selection.
 * @param nextUnion - The selection the next sources array resolves to.
 * @returns The dropped ids, in `selected` iteration order.
 */
export function droppedSelectionIds(
  selected: ReadonlySet<string>,
  nextUnion: ReadonlySet<string>,
): string[] {
  return [...selected].filter((id) => !nextUnion.has(id));
}

/**
 * Map an async board-supply read into the wizard's supply-cache entry. A
 * `null` read is a RESOLVED miss ("Deleted board"), explicitly not pending —
 * the load-state distinction the late-mutation audit (shape B) turns on.
 *
 * @param info - The resolved supply, or `null` when nothing live resolved.
 * @returns The cache entry to store for that board source.
 */
export function boardSupplyEntry(info: BoardSourceSupplyInfo | null): WizardSourceSupply {
  if (info === null) {
    return {
      displayName: 'Deleted board',
      rawSupplyTaskIds: [],
      doneTaskIds: new Set(),
    };
  }
  return {
    displayName: info.displayName,
    rawSupplyTaskIds: info.supplyTaskIds,
    doneTaskIds: info.doneTaskIds,
    // §Member rules (B3) — the windowed counts + the source board's own
    // window ride along: the remaining-target prefill and the auto-target
    // preview both read them off the supply cache, never a second board read.
    windowCountByTaskId: info.windowCountByTaskId,
    sourceWindow: info.sourceWindow,
  };
}
