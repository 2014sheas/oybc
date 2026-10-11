import { counterDisplayName, counterSearchMatches, taskSearchMatches, type Task } from '@oybc/shared';

/**
 * The counter root a task belongs to through EITHER relationship — a linked
 * copy (`sharedCounterId`) or a unit task (`countsTowardCounterId`; the two
 * never coexist) — when that root is in `pool`.
 */
function counterRootOf(task: Task, pool: readonly Task[]): Task | undefined {
  const rootId = task.sharedCounterId ?? task.countsTowardCounterId;
  if (!rootId || rootId === task.id) return undefined;
  return pool.find((t) => t.id === rootId);
}

/**
 * The counter name a list row's `UnitTag` shows: the root's display name for a
 * linked copy or a unit task, else `null` (a counter root itself never gets a
 * tag; an unresolvable root shows none). One tag for both relationships
 * (unit-tasks handoff Decision 5). iOS twin: `Helpers/RowCounterTagName.swift`.
 *
 * @param task - The row's task.
 * @param pool - Tasks to find the root in.
 * @returns The counter's display name, or null.
 */
export function rowCounterTagName(task: Task, pool: readonly Task[]): string | null {
  const root = counterRootOf(task, pool);
  if (!root) return null;
  return counterDisplayName(root) || null;
}

/**
 * The library / quick-add / Tasks-tab match with the counter's name in the
 * task's match set (Decision 7): `taskSearchMatches`, or — for a linked copy
 * or unit task — the root counter's own match texts (name, noun, verb, plural
 * title). Pass the pool once; no per-row query. iOS twin:
 * `RowCounterTagName.searchMatches`.
 *
 * @param query - The typed search.
 * @param task - The candidate task.
 * @param pool - Tasks to find the root in.
 * @returns True on a match.
 */
export function taskSearchMatchesWithCounter(query: string, task: Task, pool: readonly Task[]): boolean {
  if (taskSearchMatches(query, task)) return true;
  const root = counterRootOf(task, pool);
  return root !== undefined && counterSearchMatches(query, root);
}
