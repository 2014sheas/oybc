/**
 * countsTowardValidation.ts — the write-time half of "counts toward"
 * (docs/SHARED_COUNTER_SETTINGS.md §3a, D7 / §3e): the cross-row rules
 * `setCountsToward` ↔ `setCountsToward(taskId:counterId:)` apply before the
 * flag is stored — target must be a live Discrete counter root, the
 * contributor may not be a root / copy / achievement, and the assignment may
 * not close a feeding loop (walked transitively).
 *
 * Swift twin: `CountsToward.problem` in `Helpers/CountsToward.swift`.
 */

import { TaskType } from '../constants/enums';
import type { CompoundChild } from '../types/compoundChild';
import type { Task } from '../types/task';
import { resolveCountKind } from './countValue';
import { findTransitiveParentCompounds } from './derivationPass';

/** Why a counts-toward assignment is refused at write time. */
export type CountsTowardProblem =
  | 'self'
  | 'contributor-is-counter'
  | 'contributor-is-linked'
  | 'contributor-is-achievement'
  | 'target-not-counter'
  | 'target-not-discrete'
  | 'invalid-amount'
  | 'cycle';

/**
 * Whether `task` is a shared-counter ROOT: a hub counter, or a task other
 * live rows link to via `sharedCounterId`.
 *
 * @param task - The candidate.
 * @param tasks - Every task (any superset of the linked rows).
 */
export function isSharedCounterRoot(task: Task, tasks: ReadonlyArray<Task>): boolean {
  if (task.isCounter === true) return true;
  return tasks.some((t) => !t.isDeleted && t.sharedCounterId === task.id);
}

/** `task` and every task in its subtree (live links). */
function subtreeIds(taskId: string, children: ReadonlyArray<CompoundChild>): Set<string> {
  const seen = new Set<string>([taskId]);
  const stack = [taskId];
  while (stack.length > 0) {
    const parent = stack.pop() as string;
    for (const link of children) {
      if (link.isDeleted || link.compoundTaskId !== parent || seen.has(link.childTaskId)) continue;
      seen.add(link.childTaskId);
      stack.push(link.childTaskId);
    }
  }
  return seen;
}

/**
 * Write-time validation for `task.countsTowardCounterId = targetId` (§3a, D7).
 * Refused when: the task points at itself; the task is a counter root or a
 * linked copy, or an Achievement; the target is not a live, unlinked
 * COUNTING root (hub counter or linked-to) or not Discrete; the amount is not
 * a positive integer; or the assignment closes a feeding LOOP — walking
 * counter → (the counter and its live copies) → the compounds holding any of
 * them (transitive live parents) → each holder's own counts-toward counter →
 * …, a loop exists as soon as a node of that walk is `task` or a task in
 * `task`'s subtree (which would complete `task` again). This covers the
 * direct case (the target or a copy inside the task) and multi-hop ones
 * (X → C1 holding a copy of C2, Y → C2 holding a copy of C1).
 *
 * @param input.task - The contributing task as stored.
 * @param input.targetId - The counter it should count toward.
 * @param input.amount - The requested `countsTowardAmount` (absent = 1).
 * @param input.tasks - Every task.
 * @param input.children - Every compound link (deleted ones ignored).
 * @returns The first problem, or `null` when the assignment is allowed.
 */
export function countsTowardProblem(input: {
  task: Task;
  targetId: string;
  amount?: number;
  tasks: ReadonlyArray<Task>;
  children: ReadonlyArray<CompoundChild>;
}): CountsTowardProblem | null {
  const { task, targetId, amount, tasks, children } = input;
  if (targetId === task.id) return 'self';
  if (task.type === TaskType.ACHIEVEMENT) return 'contributor-is-achievement';
  if (task.sharedCounterId != null) return 'contributor-is-linked';
  if (isSharedCounterRoot(task, tasks)) return 'contributor-is-counter';
  const target = tasks.find((t) => t.id === targetId);
  if (!target || target.isDeleted || target.type !== TaskType.COUNTING || target.sharedCounterId != null || !isSharedCounterRoot(target, tasks)) {
    return 'target-not-counter';
  }
  if (resolveCountKind(target) !== 'discrete') return 'target-not-discrete';
  if (amount !== undefined && !(Number.isInteger(amount) && amount > 0)) return 'invalid-amount';

  const byId = new Map(tasks.map((t) => [t.id, t]));
  const liveLinks = children.filter((l) => !l.isDeleted);
  const reachesTask = subtreeIds(task.id, liveLinks);
  const visitedCounters = new Set<string>();
  const counters = [targetId];
  while (counters.length > 0) {
    const counterId = counters.pop() as string;
    if (visitedCounters.has(counterId)) continue;
    visitedCounters.add(counterId);
    const nodes = [counterId, ...tasks.filter((t) => !t.isDeleted && t.sharedCounterId === counterId).map((t) => t.id)];
    for (const node of nodes) {
      if (reachesTask.has(node)) return 'cycle';
      for (const holder of findTransitiveParentCompounds(node, liveLinks)) {
        if (reachesTask.has(holder)) return 'cycle';
        const next = byId.get(holder)?.countsTowardCounterId;
        if (next != null && !visitedCounters.has(next)) counters.push(next);
      }
    }
  }
  return null;
}
