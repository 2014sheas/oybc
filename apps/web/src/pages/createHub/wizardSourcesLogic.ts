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

import {
  removeSourceLossSentence,
  seededTargetsForSource,
  sourceConfiguration,
  sourceHasConfiguration,
  type BoardSource,
  type BoardSourceFilter,
  type BoardSourceKind,
  type BoardWindow,
  type Task,
} from '@oybc/shared';
import type {
  BoardSourceSupplyInfo,
  BoardSourceSupplyResolution,
} from '../../db/operations/boardSources';
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
 * The done-filter a NEWLY minted source row starts on — owner directive
 * 2026-09-19: "Not done yet" is the default, so pulling a board supplies
 * what is still outstanding rather than re-dealing squares the person has
 * already finished.
 *
 * KIND-SCOPED, deliberately. The done-filter is a **boards-only** field by
 * contract (docs/BOARD_SOURCES.md §The model: `filter: 'all' | 'todo' //
 * boards only; pools always 'all'`), so only `kind: 'board'` takes the
 * `'todo'` default; a pool mints `'all'` exactly as `sourcesFromMixFields`
 * (the legacy-trio decode) does. Minting a pool row on `'todo'` reads as
 * inert today — every filter read on both platforms is kind-scoped — but it
 * persists data that contradicts the contract, and the first kind-blind
 * read anyone adds would silently done-filter pool supply.
 *
 * Deliberately scoped to CREATION. Sources already stored on a board or a
 * `RecurringBoardTemplate` keep whatever filter they were saved with —
 * nothing coerces a decoded row.
 *
 * ONE definition per platform: every web mint path routes through
 * {@link appendSource}, which is this function's only caller. Swift twin:
 * `BoardWizardViewModel.newSourceFilter(for:)`.
 *
 * @param kind - Which kind of source is being minted.
 * @returns `'todo'` for a board, `'all'` for a pool.
 */
export function newSourceFilter(kind: BoardSourceKind): BoardSourceFilter {
  return kind === 'board' ? 'todo' : 'all';
}

/**
 * Append a freshly-pulled source row with the default `[0, all]` range and
 * the kind-scoped {@link newSourceFilter} done-filter. A no-op (same array identity)
 * when `sourceId` is already pulled — the sheet's tap on an already-pulled
 * row must not duplicate it or reset its range.
 *
 * No range clamp is needed here even though a board's `'todo'` shrinks the
 * eligible supply: `[0, all]` is the one range that is valid against ANY supply
 * (`clampSourceRange` leaves `min: 0` / `max: null` identity-unchanged for
 * every available count), so a row can never be minted wider than its
 * filtered supply. Every LATER supply/filter/exclude change routes through
 * `clampAllSourceRanges` as before.
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
    { sourceId, kind, min: 0, max: null, excludedTaskIds: [], filter: newSourceFilter(kind) },
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
 * What the one-off prefill would seed for this source RIGHT NOW — the input
 * that keeps the remove gate from mistaking a machine-written target for
 * configuration (amended ruling 2026-09-23).
 *
 * Empty unless the prefill itself would run: a `kind: 'board'` source on a
 * ONE-OFF wizard (`prefillRemainingTargetsOnResolve: !isRecurring` in
 * `useBoardWizard`). A pool source and every recurring session seed nothing,
 * so every stored target there is hand-set by definition.
 *
 * Recomputed per call rather than remembered from the pull, so an input that
 * has moved since makes the recomputed seed differ and the rule read as
 * configured. Known cases, all erring the same safe way (ask rather than
 * discard silently):
 *
 * - the wizard's TIMEFRAME changed after the pull — the person did change
 *   something, so asking is right;
 * - a RESUMED one-off draft, whose hydrated sources are never re-seeded, or
 *   a supply re-fetch after a sync pull: both can move
 *   `windowCountByTaskId` (it is live progress) while the stored target
 *   stays, so an otherwise untouched source asks. A report of that is this,
 *   not a bug.
 *
 * @param source - The pulled source row.
 * @param supply - Its resolved supply (`windowCountByTaskId` + `sourceWindow`).
 * @param tasksById - LIBRARY-backed id → task (`library.taskMap`), the same
 *   map the prefill read — never the staged-edit overlay. An inline goal
 *   edit must not shift the recomputed seed: the staged edit lives on the
 *   task and survives the removal, so claiming "1 member rule" would be
 *   false.
 * @param targetWindow - The window of the board being assembled.
 * @param isRecurring - Whether this is a repeating-board session.
 * @returns id → seeded target, or `{}` when nothing would be seeded.
 */
export function seededTargetsForRemoval(
  source: BoardSource,
  supply: WizardSourceSupply | undefined,
  tasksById: Record<string, Task | undefined>,
  targetWindow: BoardWindow,
  isRecurring: boolean,
): Record<string, number> {
  if (isRecurring || source.kind !== 'board' || supply === undefined) return {};
  return seededTargetsForSource(
    {
      supplyTaskIds: supply.rawSupplyTaskIds,
      windowCountByTaskId: supply.windowCountByTaskId,
      sourceWindow: supply.sourceWindow,
    },
    tasksById,
    targetWindow,
  );
}

/**
 * Whether dropping this source should ask first — the wizard Tasks step's
 * remove gate (owner ruling 2026-09-19: an untouched source removes
 * instantly; one carrying exclusions / authored member rules / a narrowed
 * range / a flipped filter asks, because a misclick on the row's ✕ was
 * throwing that work away silently).
 *
 * This exists so the kind-scoped default ({@link newSourceFilter}) is
 * applied in exactly ONE place: the shared predicate compares against the
 * CREATION default, and passing the legacy-decode `'all'` instead would
 * make every freshly pulled board look configured.
 *
 * @param source - The pulled source row the ✕ (or a sheet un-toggle) named.
 * @param seededTargetByTaskId - From {@link seededTargetsForRemoval}; a
 *   target equal to its seed is the prefill's own write, not configuration.
 * @returns True when a confirm is owed.
 */
export function sourceRemovalNeedsConfirm(
  source: BoardSource,
  seededTargetByTaskId?: Record<string, number>,
): boolean {
  return sourceHasConfiguration(source, newSourceFilter(source.kind), seededTargetByTaskId);
}

/**
 * The confirm's body copy: what removing this source would cost, worded by
 * the shared `removeSourceLossSentence` so web and iOS can't drift.
 *
 * @param source - The pulled source row.
 * @param seededTargetByTaskId - See {@link sourceRemovalNeedsConfirm}.
 * @returns The sentence, or `null` when the row carries nothing (in which
 *   case {@link sourceRemovalNeedsConfirm} is false and no dialog opens).
 */
export function sourceRemovalLossSentence(
  source: BoardSource,
  seededTargetByTaskId?: Record<string, number>,
): string | null {
  return removeSourceLossSentence(
    sourceConfiguration(source, newSourceFilter(source.kind), seededTargetByTaskId),
  );
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

/**
 * Map a window-aware board-supply resolution into the wizard's supply-cache
 * entry: `live` → {@link boardSupplyEntry}; `dead` → the "Deleted board"
 * miss; `noWindow` → the stored board's name, an empty supply and
 * `noBoardForWindow` (the row's "No board for this window yet" subtitle —
 * owner ruling 2026-09-24). iOS twin: `WizardSourceSupply.init(resolution:)`.
 *
 * @param resolution - From `fetchBoardSourceSupplyForWindow`.
 * @returns The cache entry to store for that board source.
 */
export function boardSupplyEntryForResolution(
  resolution: BoardSourceSupplyResolution,
): WizardSourceSupply {
  if (resolution.kind === 'live') return boardSupplyEntry(resolution.info);
  if (resolution.kind === 'dead') return boardSupplyEntry(null);
  return {
    displayName: resolution.displayName,
    rawSupplyTaskIds: [],
    doneTaskIds: new Set(),
    noBoardForWindow: true,
  };
}
