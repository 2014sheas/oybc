import { isGoalLessCounter, taskSearchMatches, type Task } from '@oybc/shared';
import { counterNameMatches, lookupValues, type TaskLookup } from '../counters/rowCounterTagName';

/**
 * poolEditSheetSelectors.ts — pure derivations `PoolEditorBody` needs from
 * its raw `taskIds` + task lookups (Task Pools + Recurring Boards Rework,
 * P2 final review I-2/I-3). Extracted from the component so both
 * concerns have a directly testable seam without a component-render
 * harness (mirrors `poolDeckPreview.ts` / `poolEditSheetOps.ts`).
 */

/**
 * The library-reuse picker's candidate list (I-2): `browsableTasks` (the
 * SAME draft-filtered set the Library segment browses — never the raw,
 * un-filtered task set) minus ids already on the pool, filtered by the
 * shared `taskSearchMatches` (title, plus a counter's name / noun / verb /
 * plural template — docs/SHARED_COUNTER_SETTINGS.md §2) then, ranked after
 * those direct hits, a unit task / linked copy found by its counter's name or
 * noun (`counterNameMatches`; `lookup` resolves the root — pass the unfiltered
 * task set, the browse filter drops goal-less counters); case- and
 * diacritic-insensitive. Pickers are browse surfaces — a
 * wizard-born draft task the Library tab hides shouldn't be offered here
 * either, even though a pool that already references one still resolves
 * its chip via `resolvePoolChips` below (which reads the full set).
 */
export function selectLibraryPickerResults(
  browsableTasks: readonly Task[],
  selectedIds: ReadonlySet<string>,
  query: string,
  lookup: TaskLookup = browsableTasks,
): Task[] {
  const candidates = browsableTasks.filter((t) => !selectedIds.has(t.id));
  // Direct hits (title / the counter's own fields) rank ahead of counter-name-only hits.
  const direct = candidates.filter((t) => taskSearchMatches(query, t));
  const viaCounter = candidates.filter((t) => !taskSearchMatches(query, t) && counterNameMatches(query, t, lookup));
  return [...direct, ...viaCounter];
}

/** Cap for `selectQuickAddMatches`'s inline dropdown — the quick-add row
 *  is a compact affordance, not a full browse picker, so results are
 *  capped tighter than the unbounded `selectLibraryPickerResults` list
 *  the "Reuse a task from your library" picker renders. */
export const QUICK_ADD_MATCH_CAP = 4;

/**
 * Quick-add library-poll matches (Quick-add library polling, owner
 * decision 2026-07-21) — `WizardQuickAddRow`'s inline dropdown seam. A
 * thin cap over `selectLibraryPickerResults`: reuses its exclude +
 * title-contains filtering verbatim (never reinvented) and truncates to
 * `QUICK_ADD_MATCH_CAP` for the compact inline UI.
 *
 * `includeGoalLessCounters` (a host that renders counter match rows — it
 * knows the board's timeframe): goal-less counters (every counter created
 * from the Counters hub has no `maxCount`) are hidden from browsing, so they
 * are never in `browsableTasks`; they join the candidates from `lookup` so
 * typing a new counter's name finds it, and its match row places it with the
 * board-timeframe default or asks for a goal. Off elsewhere (pools,
 * compound children), where a goal-less counter cannot be added.
 */
export function selectQuickAddMatches(
  browsableTasks: readonly Task[],
  selectedIds: ReadonlySet<string>,
  query: string,
  lookup: TaskLookup = browsableTasks,
  includeGoalLessCounters = false,
): Task[] {
  return selectLibraryPickerResults(
    includeGoalLessCounters ? withGoalLessCounters(browsableTasks, lookup) : browsableTasks,
    selectedIds,
    query,
    lookup,
  ).slice(0, QUICK_ADD_MATCH_CAP);
}

/**
 * `browsableTasks` plus every live goal-less counter ROOT in `lookup` (not a
 * fork, not itself linked) that isn't already in it, appended in lookup order.
 *
 * @param browsableTasks - The browse-filtered candidates.
 * @param lookup - The surface's full task set.
 * @returns The widened candidate list.
 */
export function withGoalLessCounters(browsableTasks: readonly Task[], lookup: TaskLookup): readonly Task[] {
  const ids = new Set(browsableTasks.map((t) => t.id));
  const extra = lookupValues(lookup).filter(
    (t) => !t.isDeleted && isGoalLessCounter(t) && t.forkedFromTaskId == null && t.sharedCounterId == null && !ids.has(t.id),
  );
  return extra.length === 0 ? browsableTasks : [...browsableTasks, ...extra];
}

/**
 * Resolves a pool's raw `taskIds` (which may include ids that don't
 * resolve — soft-deleted or otherwise missing, preserved per `Pool`'s
 * docstring contract) into the RESOLVABLE subset, in `taskIds` order
 * (I-3). This — never the raw id list — is what the sheet's "TASKS (N)"
 * count, chip row, and deck preview render, matching
 * `computePoolHealth`'s "resolvable, non-deleted" count semantics.
 *
 * `sessionCache` supplements `tasksById` for a task added earlier this
 * session (quick-add / library-pick) that may not have round-tripped
 * through the caller's live-query snapshot yet — sidesteps a title flash.
 */
export function resolvePoolChips(
  taskIds: readonly string[],
  tasksById: ReadonlyMap<string, Task>,
  sessionCache: ReadonlyMap<string, Task>,
): Task[] {
  const out: Task[] = [];
  for (const id of taskIds) {
    const task = tasksById.get(id) ?? sessionCache.get(id);
    if (task) out.push(task);
  }
  return out;
}
