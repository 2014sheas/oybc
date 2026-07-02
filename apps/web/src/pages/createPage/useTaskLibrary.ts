import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  BoardStatus,
  computeBrowsableTasks,
  type Task,
  type CompoundChild,
  type Board,
  type BoardTask,
} from '@oybc/shared';
import { db } from '../../db/database';
import { useTasks } from '../../hooks';

export type ExistingFilter = 'all' | 'normal' | 'counting' | 'compound';

// Stable empty fallbacks for `?? FALLBACK` — see BoardPlayPage.tsx for rationale.
const EMPTY_TASKS = Object.freeze([]) as unknown as Task[];
const EMPTY_COMPOUND_CHILDREN = Object.freeze([]) as unknown as CompoundChild[];
const EMPTY_BOARD_TASKS = Object.freeze([]) as unknown as BoardTask[];
const EMPTY_BOARDS = Object.freeze([]) as unknown as Board[];

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
  /** Every task id that appears as a child of at least one compound.
   *  Used by the nesting chip to suppress children from the top-level pool. */
  childTaskIds: Set<string>;
  /** Reverse map: child task id → array of parent compound task ids.
   *  A child can belong to multiple parents (multi-parent display). */
  childToParents: Record<string, string[]>;
}

export function useTaskLibrary(userId: string | undefined): TaskLibrary {
  const allTasks = useTasks(userId) ?? EMPTY_TASKS;

  // CompoundChild has no userId column (children scope to a parent Task),
  // so a workspace-wide query would leak rows from a previous user across an
  // account switch on the same device (signOut only clears the sync queue,
  // not entity tables). Live-query the workspace then filter to the current
  // user's compound parents in JS — small-N, single-pass — so cross-account
  // pollution can't influence grouping/evaluation/cascade work.
  const userCompoundIds = useMemo(() => {
    const ids = new Set<string>();
    for (const t of allTasks) {
      if (t.type === TaskType.COMPOUND) ids.add(t.id);
    }
    return ids;
  }, [allTasks]);
  const allCompoundChildrenWorkspace =
    useLiveQuery(
      () => db.compoundChildren.filter((c: CompoundChild) => !c.isDeleted).toArray(),
      [],
    ) ?? EMPTY_COMPOUND_CHILDREN;
  const allCompoundChildren = useMemo(
    () => allCompoundChildrenWorkspace.filter((c) => userCompoundIds.has(c.compoundTaskId)),
    [allCompoundChildrenWorkspace, userCompoundIds],
  );

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

  // Issue #73 — derive the child-id set + reverse (child → parents) map
  // from the already-grouped links. Both are pure functions of
  // `compoundChildrenByCompound`, so they recompute only when it does.
  const { childTaskIds, childToParents } = useMemo(() => {
    const ids = new Set<string>();
    const parents: Record<string, string[]> = {};
    for (const [compoundId, children] of Object.entries(compoundChildrenByCompound)) {
      for (const c of children) {
        ids.add(c.childTaskId);
        (parents[c.childTaskId] ??= []).push(compoundId);
      }
    }
    return { childTaskIds: ids, childToParents: parents };
  }, [compoundChildrenByCompound]);

  return {
    allTasks,
    allCompoundChildren,
    taskMap,
    compoundChildrenByCompound,
    childTaskIds,
    childToParents,
  };
}

/**
 * The draft-filtered subset of `allTasks` to BROWSE — hides wizard-born tasks
 * that live only on draft boards (or are orphaned, e.g. removed from the pool)
 * until they land on a live non-draft board. Mirrors iOS
 * `TaskLibraryViewModel.browsableTasks`.
 *
 * Subscribes to the boards + board_tasks tables, so call this ONLY from browse
 * surfaces (the Tasks tab, the wizard "add from library"). Lookup-only callers
 * of `useTaskLibrary` (BoardPlaySurface, RisoBoard, …) must NOT pay for these
 * subscriptions — that's why this is a separate hook.
 */
export function useBrowsableTasks(allTasks: Task[]): Task[] {
  const allBoardTasks =
    useLiveQuery(() => db.boardTasks.toArray(), []) ?? EMPTY_BOARD_TASKS;
  const allBoards =
    useLiveQuery(
      () => db.boards.filter((b: Board) => !b.isDeleted).toArray(),
      [],
    ) ?? EMPTY_BOARDS;
  const boardStatusById = useMemo(() => {
    const m: Record<string, BoardStatus> = {};
    for (const b of allBoards) m[b.id] = b.status;
    return m;
  }, [allBoards]);
  return useMemo(
    () => computeBrowsableTasks(allTasks, allBoardTasks, boardStatusById),
    [allTasks, allBoardTasks, boardStatusById],
  );
}

/**
 * Apply the Existing-Tasks filter to the library.
 *   - 'all'      — every task
 *   - 'normal'   — type=normal
 *   - 'counting' — type=counting
 *   - 'compound' — type=compound (both ordered and unordered)
 *
 * Returns a single flat list. Consumers iterate `filteredTasks` and
 * inspect `task.type` + `task.isOrdered` to render appropriately.
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
      case 'compound':
        return t.type === TaskType.COMPOUND;
      default:
        return false;
    }
  });
  return { filteredTasks: filtered };
}
