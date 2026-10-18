import {
  TaskType,
  counterDisplayName,
  isTaskExpired,
  placementGoalForCounter,
  placementNeedsOverride,
  resolveCountKind,
  sharedCounterRootIds,
  type PlacementBoard,
  type PlacementParams,
  type Task,
} from '@oybc/shared';
import { taskLookupValues, type TaskLookup } from '../counters/rowCounterTagName';

/**
 * quickAddCounterPlacement.ts — the pure half of the quick-add / picker match
 * row for a shared counter (docs/SHARED_COUNTER_SETTINGS.md §2; design
 * handoff `PlaceFrame.dc.html`): which rows are counters and the PLACEMENT
 * PARAMETERS a quick-added / hand-edited counter goal becomes
 * (TASK_WINDOW_REWORK slice 3b — the wizard places the ROOT itself with a
 * `targetOverride`; no per-board copy row exists). iOS twin:
 * `QuickAddCounterPlacement.swift`.
 */

/**
 * Is this library task a shared counter ROOT the match row treats specially:
 * a counting task with no `sharedCounterId` that is a hub counter, carries
 * timeframe defaults, or is linked to by another live task (`linkedRootIds`,
 * from {@link counterRootIdsIn}) — the same roots the Tasks tab shows as
 * counters, so every search surface returns the COUNTER for them.
 *
 * @param task - A library task.
 * @param linkedRootIds - Ids other live tasks link to (default: none).
 */
export function isSharedCounterRoot(task: Task, linkedRootIds: ReadonlySet<string> = NO_IDS): boolean {
  if (task.type !== TaskType.COUNTING || task.sharedCounterId) return false;
  return (
    task.isCounter === true ||
    Object.keys(task.timeframeGoals ?? {}).length > 0 ||
    linkedRootIds.has(task.id)
  );
}

const NO_IDS: ReadonlySet<string> = new Set();

/**
 * Is this task one the browse surfaces (Tasks tab, Library sheet) hide as
 * expired: past its own `endDate` (`isTaskExpired`) and NOT a counter root. A
 * root created inside a board wizard carries that board's window, but it is
 * the counter — a live family whatever its own window — so it stays listed.
 * iOS twin: `QuickAddCounterPlacement.isExpiredForBrowse`.
 *
 * @param task - A library task.
 * @param linkedRootIds - {@link counterRootIdsIn} over the surface's full task set.
 * @param now - Reference time for the expiry check.
 */
export function isExpiredForBrowse(task: Task, linkedRootIds: ReadonlySet<string>, now: Date = new Date()): boolean {
  return !isSharedCounterRoot(task, linkedRootIds) && isTaskExpired(task, now);
}

/**
 * The counter roots in a surface's FULL task set (`sharedCounterRootIds`: a
 * hub counter, or a task another live task links to) — pass the unfiltered
 * set: the browse list drops the linked members that make a root.
 *
 * @param lookup - The surface's full task set (map or list).
 */
export function counterRootIdsIn(lookup: TaskLookup): Set<string> {
  return sharedCounterRootIds(taskLookupValues(lookup));
}

/**
 * The placement parameters a counter ROOT's `goal` on a board window needs:
 * `{ targetOverride, targetKind }` unless the goal is the root's own AND no
 * window default would override it at persist (then the plain task is the
 * placement and there are no parameters). An explicit goal that equals the
 * root's own while the window default differs IS kept — the planner would
 * otherwise re-apply the default over the person's choice.
 *
 * @param root - The counter root.
 * @param goal - The goal in the root's kind (positive), or null.
 * @param window - The host board's window.
 * @returns The parameters to carry, or null for none.
 */
export function counterGoalParams(root: Task, goal: number | null | undefined, window: PlacementBoard): PlacementParams | null {
  if (goal == null || !(goal > 0)) return null;
  if (goal === root.maxCount && !placementNeedsOverride(root, window)) return null;
  return { targetOverride: goal, targetKind: resolveCountKind(root) };
}

/**
 * The parameters quick-adding a counter ROOT carries: the root's goal for the
 * host window (its timeframe default), when that differs from its own goal.
 * iOS twin: `QuickAddCounterPlacement.quickAddPlacementParams`.
 *
 * @param root - The counter root.
 * @param window - The host board's window.
 * @returns The parameters, or null when the root places as-is.
 */
export function quickAddPlacementParams(root: Task, window: PlacementBoard): PlacementParams | null {
  return counterGoalParams(root, placementGoalForCounter(root, window), window);
}

/**
 * The wizard's per-cell parameters re-stamped for a CHANGED window: a counter
 * whose override was the OLD window's default follows to the new window's
 * default; a typed goal stays. iOS twin:
 * `QuickAddCounterPlacement.restampedPlacementParams`.
 *
 * @param params - The wizard's parameters keyed by task id.
 * @param rootOf - Looks up the counter root for a task id.
 * @param from - The window the parameters were last stamped for.
 * @param to - The board's current window.
 * @returns The same map when nothing moved, else a new one.
 */
export function restampPlacementParams(
  params: ReadonlyMap<string, PlacementParams>,
  rootOf: (id: string) => Task | undefined,
  from: PlacementBoard,
  to: PlacementBoard,
): ReadonlyMap<string, PlacementParams> {
  let next: Map<string, PlacementParams> | null = null;
  for (const [id, p] of params) {
    const root = rootOf(id);
    if (!root || p.targetOverride == null || p.targetOverride !== placementGoalForCounter(root, from)) continue;
    const moved = quickAddPlacementParams(root, to);
    next ??= new Map(params);
    if (moved) next.set(id, moved);
    else next.delete(id);
  }
  return next ?? params;
}

/**
 * The counter name a match row shows for a root.
 *
 * @param root - The counter root.
 */
export function counterMatchRowName(root: Task): string {
  return counterDisplayName(root) || root.title || '(untitled task)';
}

/**
 * The ids a quick-add dropdown leaves out: the surface's selected ids plus
 * every counter a selected task is LINKED to — a counter already on this
 * board (itself, or as its linked copy) is not offered again (owner rule
 * 2026-10-13: one per scope). iOS twin: `RisoQuickAddRowView.libraryMatches`.
 *
 * @param selectedIds - Ids already on the surface.
 * @param lookup - The surface's full task set (pending rows included).
 * @returns The ids to exclude.
 */
export function quickAddExcludedIds(selectedIds: ReadonlySet<string>, lookup: TaskLookup): Set<string> {
  const excluded = new Set(selectedIds);
  for (const t of taskLookupValues(lookup)) {
    if (t.sharedCounterId && selectedIds.has(t.id)) excluded.add(t.sharedCounterId);
  }
  return excluded;
}
