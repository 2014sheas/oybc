import { useMemo } from 'react';
import { counterDisplayName, isCountsTowardTarget, isSharedCounterRoot, resolveCountKind, type CountKind, type Task } from '@oybc/shared';
import { useTasks } from './useTasks';

/** One pickable "Counts toward" target — a live Discrete shared-counter root. */
export interface CountsTowardTarget {
  id: string;
  /** `counterDisplayName(root)`. */
  name: string;
  /** The root's all-time total (its lifetime cache — the hub's rule). */
  lifetime: number;
  kind: CountKind;
  task: Task;
}

/**
 * The counters a task may count toward: every live, unlinked Discrete
 * COUNTING root (`isCountsTowardTarget` + `isSharedCounterRoot`), minus the
 * edited task itself, sorted by name. Reactive via `useTasks`.
 *
 * @param userId - The signed-in user.
 * @param excludeTaskId - The task being edited (never its own target).
 */
export function useCountsTowardTargets(userId: string | undefined, excludeTaskId?: string): CountsTowardTarget[] {
  const tasks = useTasks(userId);
  return useMemo(() => selectCountsTowardTargets(tasks ?? [], excludeTaskId), [tasks, excludeTaskId]);
}

/**
 * Pure selection behind {@link useCountsTowardTargets}.
 *
 * @param tasks - Every live task.
 * @param excludeTaskId - The task being edited.
 */
export function selectCountsTowardTargets(tasks: ReadonlyArray<Task>, excludeTaskId?: string): CountsTowardTarget[] {
  return tasks
    .filter((t) => t.id !== excludeTaskId && isCountsTowardTarget(t) && isSharedCounterRoot(t, tasks))
    .map((t) => ({ id: t.id, name: counterDisplayName(t), lifetime: t.currentCount ?? 0, kind: resolveCountKind(t), task: t }))
    .sort((a, b) => a.name.localeCompare(b.name) || (a.id < b.id ? -1 : 1));
}
