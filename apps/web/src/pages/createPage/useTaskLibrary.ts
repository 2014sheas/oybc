import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { TaskType, type Task, type TaskStep, type CompositeTask, type CompositeNode } from '@oybc/shared';
import { db } from '../../db/database';
import { useTasks } from '../../hooks';
import { useCompositeTasks } from '../../hooks/useCompositeTasks';

export const COMPOSITE_TYPE = 'composite' as const;
export type TaskTypeOrComposite = TaskType | typeof COMPOSITE_TYPE;
export type ExistingFilter = 'all' | TaskTypeOrComposite;

/**
 * Loads the full task/composite library for the authenticated user and
 * exposes both raw lists and indexed lookup maps for O(1) id→entity
 * resolution. Keeps the Create page's container free of data-layer
 * plumbing.
 *
 * - `allTasks` / `allCompositeTasks` — reactive (`dexie-react-hooks`)
 *   lists scoped to `userId`.
 * - `allCompositeNodes` — scoped by parent `compositeTaskId` set.
 *   `CompositeNode` has no `userId` of its own, so we filter by the
 *   user's composite ids.
 * - `allTaskSteps` — scoped by parent `taskId` set; same story.
 * - `taskMap` / `compositeTaskMap` — identity indexes rebuilt whenever
 *   the underlying list changes.
 *
 * The joined-key dependency (e.g. `compositeIds.join(',')`) is the
 * same memoisation handle the original inline `useLiveQuery` used —
 * the list-identity comparison avoids re-querying on every render.
 */
export interface TaskLibrary {
  allTasks: Task[];
  allCompositeTasks: CompositeTask[];
  allCompositeNodes: CompositeNode[];
  allTaskSteps: TaskStep[];
  taskMap: Record<string, Task>;
  compositeTaskMap: Record<string, CompositeTask>;
}

export function useTaskLibrary(userId: string | undefined): TaskLibrary {
  const allTasks = useTasks(userId) ?? [];
  const allCompositeTasks = useCompositeTasks(userId) ?? [];

  const compositeIds = allCompositeTasks.map((ct) => ct.id);
  const allCompositeNodes =
    useLiveQuery(
      async () => {
        if (compositeIds.length === 0) return [] as CompositeNode[];
        return db.compositeNodes
          .where('compositeTaskId')
          .anyOf(compositeIds)
          .and((n: CompositeNode) => !n.isDeleted)
          .toArray();
      },
      [compositeIds.join(',')]
    ) ?? [];

  const userTaskIds = allTasks.map((t) => t.id);
  const allTaskSteps: TaskStep[] =
    useLiveQuery(
      async () => {
        if (userTaskIds.length === 0) return [] as TaskStep[];
        return db.taskSteps
          .where('taskId')
          .anyOf(userTaskIds)
          .and((s: TaskStep) => !s.isDeleted)
          .toArray();
      },
      [userTaskIds.join(',')]
    ) ?? [];

  const taskMap = useMemo(() => {
    const m: Record<string, Task> = {};
    for (const t of allTasks) m[t.id] = t;
    return m;
  }, [allTasks]);

  const compositeTaskMap = useMemo(() => {
    const m: Record<string, CompositeTask> = {};
    for (const ct of allCompositeTasks) m[ct.id] = ct;
    return m;
  }, [allCompositeTasks]);

  return {
    allTasks,
    allCompositeTasks,
    allCompositeNodes,
    allTaskSteps,
    taskMap,
    compositeTaskMap,
  };
}

/**
 * Apply the Existing-Tasks filter to the library. Pulled out of the
 * hook so callers can re-derive with different filters without
 * re-running the underlying live queries.
 */
export function filterLibraryForDisplay(
  library: TaskLibrary,
  filter: ExistingFilter
): { filteredTasks: Task[]; filteredCompositeTasks: CompositeTask[] } {
  const filteredTasks: Task[] =
    filter === 'all'
      ? library.allTasks
      : filter === COMPOSITE_TYPE
        ? []
        : library.allTasks.filter((t) => t.type === filter);

  const filteredCompositeTasks: CompositeTask[] =
    filter === 'all' || filter === COMPOSITE_TYPE ? library.allCompositeTasks : [];

  return { filteredTasks, filteredCompositeTasks };
}
