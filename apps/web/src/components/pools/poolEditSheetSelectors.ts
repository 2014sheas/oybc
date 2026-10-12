import { isGoalLessCounter, taskSearchMatches, type Task } from '@oybc/shared';
import { counterNameMatches, type TaskLookup } from '../counters/rowCounterTagName';

/**
 * poolEditSheetSelectors.ts — pure derivations `PoolEditorBody` needs from
 * its raw `taskIds` + task lookups (Task Pools + Recurring Boards Rework,
 * P2 final review I-2/I-3). Extracted from the component so both
 * concerns have a directly testable seam without a component-render
 * harness (mirrors `poolDeckPreview.ts` / `poolEditSheetOps.ts`).
 */

/**
 * The quick-add reuse matches' candidate list (I-2): `browsableTasks` (the
 * SAME draft-filtered set the Library segment browses — never the raw,
 * un-filtered task set) minus ids already on the pool, filtered by the
 * shared `taskSearchMatches` (title, plus a counter's name / noun / verb /
 * plural template — docs/SHARED_COUNTER_SETTINGS.md §2) then, ranked after
 * those direct hits, a unit task / linked copy found by its counter's name or
 * noun (`counterNameMatches`; `lookup` resolves the root — pass the unfiltered
 * task set, the browse filter drops linked members); case- and
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
 *  is a compact affordance (the one library-reuse surface since the
 *  separate "Reuse a task from your library" picker was retired). */
export const QUICK_ADD_MATCH_CAP = 4;

/**
 * Quick-add library-poll matches (Quick-add library polling, owner
 * decision 2026-07-21) — `WizardQuickAddRow`'s inline dropdown seam. A
 * thin cap over `selectLibraryPickerResults`: reuses its exclude +
 * title-contains filtering verbatim (never reinvented) and truncates to
 * `QUICK_ADD_MATCH_CAP` for the compact inline UI.
 *
 * `excludeGoalLessCounters`: a counter with no goal of its own (every counter
 * created from the Counters hub) is browsable and places at the board
 * window's default (`windowDefaultGoal` — the kind fallback when none is
 * set), so it matches by default; `true` drops it for the one host that
 * can't take one (a compound sub-task).
 */
export function selectQuickAddMatches(
  browsableTasks: readonly Task[],
  selectedIds: ReadonlySet<string>,
  query: string,
  lookup: TaskLookup = browsableTasks,
  excludeGoalLessCounters = false,
): Task[] {
  return selectLibraryPickerResults(
    excludeGoalLessCounters ? browsableTasks.filter((t) => !isGoalLessCounter(t)) : browsableTasks,
    selectedIds,
    query,
    lookup,
  ).slice(0, QUICK_ADD_MATCH_CAP);
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
