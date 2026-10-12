import { counterDisplayName, normalizeSearchText, taskSearchMatches, type Task } from '@oybc/shared';

/**
 * Where a row resolves its counter root: a full id-keyed map (preferred — the
 * surface's unfiltered task map, so a root the surface's filter drops still
 * resolves), or a task list (linear scan).
 */
export type TaskLookup = readonly Task[] | ReadonlyMap<string, Task> | Readonly<Record<string, Task>>;

function lookupTask(lookup: TaskLookup, id: string): Task | undefined {
  if (Array.isArray(lookup)) return (lookup as readonly Task[]).find((t) => t.id === id);
  if (lookup instanceof Map) return (lookup as ReadonlyMap<string, Task>).get(id);
  return (lookup as Readonly<Record<string, Task>>)[id];
}

/**
 * The counter root a task belongs to through EITHER relationship — a linked
 * copy (`sharedCounterId`) or a unit task (`countsTowardCounterId`; the two
 * never coexist) — when that root resolves in `lookup`. A counter root itself
 * has none.
 */
function counterRootOf(task: Task, lookup: TaskLookup): Task | undefined {
  if (task.isCounter) return undefined;
  const rootId = task.sharedCounterId ?? task.countsTowardCounterId;
  if (!rootId || rootId === task.id) return undefined;
  return lookupTask(lookup, rootId);
}

/**
 * The counter name a list row's `UnitTag` shows: the root's display name for a
 * linked copy or a unit task, else `null` (a counter root itself never gets a
 * tag; an unresolvable root shows none). One tag for both relationships
 * (unit-tasks handoff Decision 5). iOS twin: `Helpers/RowCounterTagName.swift`.
 *
 * @param task - The row's task.
 * @param lookup - The surface's full task set (map or list) to find the root in.
 * @returns The counter's display name, or null.
 */
export function rowCounterTagName(task: Task, lookup: TaskLookup): string | null {
  const root = counterRootOf(task, lookup);
  if (!root) return null;
  return counterDisplayName(root) || null;
}

/**
 * Does `query` hit this task's counter by name? The root's display name or its
 * noun (unit) only — not the verb, plural template or stored title (Decision 7).
 */
export function counterNameMatches(query: string, task: Task, lookup: TaskLookup): boolean {
  const q = normalizeSearchText(query);
  if (q.length === 0) return false;
  const root = counterRootOf(task, lookup);
  if (!root) return false;
  return [counterDisplayName(root), root.unit ?? ''].some((t) => normalizeSearchText(t).includes(q));
}

/**
 * The library / quick-add / Tasks-tab match with the counter's name in the
 * task's match set (Decision 7): `taskSearchMatches`, or the counter-name hit
 * above for a linked copy / unit task. Pass the lookup once; no per-row query.
 * iOS twin: `RowCounterTagName.searchMatches`.
 *
 * @param query - The typed search.
 * @param task - The candidate task.
 * @param lookup - The surface's full task set to find the root in.
 * @returns True on a match.
 */
export function taskSearchMatchesWithCounter(query: string, task: Task, lookup: TaskLookup): boolean {
  return taskSearchMatches(query, task) || counterNameMatches(query, task, lookup);
}
