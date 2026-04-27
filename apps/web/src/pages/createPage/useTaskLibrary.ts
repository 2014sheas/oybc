import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { TaskType, type Task, type CompoundChild } from '@oybc/shared';
import { db } from '../../db/database';
import { useTasks } from '../../hooks';

export type ExistingFilter = 'all' | 'normal' | 'counting' | 'progress' | 'composite';

// Stable empty fallbacks for `?? FALLBACK` — see BoardPlayPage.tsx for rationale.
const EMPTY_TASKS = Object.freeze([]) as unknown as Task[];
const EMPTY_COMPOUND_CHILDREN = Object.freeze([]) as unknown as CompoundChild[];

/**
 * Loads the user's task library — unified under the compound model.
 *
 * Compounds live in `tasks` with `type='compound'`. The legacy
 * `composite_tasks` / `composite_nodes` tables were dropped in Dexie v5;
 * the only collections this hook touches now are `tasks` and the new
 * `compoundChildren`.
 *
 * - `allTasks` — every non-deleted Task for the user (all four types
 *   represented as TaskType.NORMAL / .COUNTING / .COMPOUND, plus the
 *   deprecated TaskType.PROGRESS alias for legacy rows).
 * - `allCompoundChildren` — every non-deleted compoundChildren row in the
 *   workspace. Small-N: one row per parent-child link, typically under
 *   a few hundred per user.
 * - `taskMap` — id → Task lookup, rebuilt whenever the list changes.
 * - `compoundChildrenByCompound` — pre-grouped lookup keyed by parent
 *   compoundTaskId. Consumers (BoardWizardTasksStep, BingoBoard, the
 *   compound detail sheet) build this same map in their own renders;
 *   exposing it here saves duplicate work.
 */
export interface TaskLibrary {
  allTasks: Task[];
  allCompoundChildren: CompoundChild[];
  taskMap: Record<string, Task>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
}

export function useTaskLibrary(userId: string | undefined): TaskLibrary {
  const allTasks = useTasks(userId) ?? EMPTY_TASKS;

  // Workspace-wide compoundChildren — small-N, no per-user filter (children
  // don't carry userId; they're scoped via the parent Task's userId, which
  // is implicitly the authenticated user since `tasks` is already userId-
  // scoped). Live query for reactivity.
  const allCompoundChildren =
    useLiveQuery(
      () => db.compoundChildren.filter((c: CompoundChild) => !c.isDeleted).toArray(),
      [],
    ) ?? EMPTY_COMPOUND_CHILDREN;

  const taskMap = useMemo(() => {
    const m: Record<string, Task> = {};
    for (const t of allTasks) m[t.id] = t;
    return m;
  }, [allTasks]);

  const compoundChildrenByCompound = useMemo(() => {
    const m: Record<string, CompoundChild[]> = {};
    for (const c of allCompoundChildren) {
      (m[c.compoundTaskId] ??= []).push(c);
    }
    // Sort each parent's children by childIndex so consumers don't have to.
    for (const id of Object.keys(m)) {
      m[id].sort((a, b) => a.childIndex - b.childIndex);
    }
    return m;
  }, [allCompoundChildren]);

  return {
    allTasks,
    allCompoundChildren,
    taskMap,
    compoundChildrenByCompound,
  };
}

/**
 * Apply the Existing-Tasks filter to the library. Five user-facing tabs
 * map onto two underlying classifications:
 *   - 'all'       — every task
 *   - 'normal'    — type=normal
 *   - 'counting'  — type=counting
 *   - 'progress'  — type=compound && isOrdered=true   (former Progress UX)
 *   - 'composite' — type=compound && isOrdered=false  (former Composite UX)
 *
 * Returns a single flat list (no separate composite array — the legacy
 * `filteredCompositeTasks` field is gone). Consumers iterate `filteredTasks`
 * and inspect `task.type` + `task.isOrdered` to render appropriately.
 */
export function filterLibraryForDisplay(
  library: TaskLibrary,
  filter: ExistingFilter,
): { filteredTasks: Task[] } {
  const filtered = library.allTasks.filter((t) => {
    switch (filter) {
      case 'all':
        return true;
      case 'normal':
        return t.type === TaskType.NORMAL;
      case 'counting':
        return t.type === TaskType.COUNTING;
      case 'progress':
        return t.type === TaskType.COMPOUND && t.isOrdered === true;
      case 'composite':
        return t.type === TaskType.COMPOUND && t.isOrdered !== true;
      default:
        return false;
    }
  });
  return { filteredTasks: filtered };
}
