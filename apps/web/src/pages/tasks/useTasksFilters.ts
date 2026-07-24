import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  BoardStatus,
  TaskType,
  computeBrowsableTasks,
  isTaskExpired,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { fetchAllBoards, fetchAllBoardTasks } from '../../db/operations';
import type { TaskLibrary } from '../createPage/useTaskLibrary';

/** Type-filter chips on the Tasks tab. Mirrors the wizard's set but
 *  adds ACHIEVEMENT (which the wizard hides because achievements can't
 *  be placed on a board pool). 'compound' matches ALL compound tasks
 *  (both ordered and unordered — the isOrdered distinction is internal). */
export type TypeFilter =
  | 'all'
  | 'normal'
  | 'counting'
  | 'compound'
  | 'achievement';

/** Status-filter dropdown values. "Never started" = not completed and
 *  no progress signal; "In progress" = some signal but not done. */
export type StatusFilter = 'any' | 'completed' | 'in-progress' | 'never-started';

/** Usage-filter dropdown values. Computed from `BoardTask` joined to
 *  `Board.status` (we only count non-deleted, non-draft placements). */
export type UsageFilter = 'any' | 'unused' | 'on-active-boards';

/** Sort options for the Tasks list. `most-used-desc` ranks by the
 *  count of `BoardTask` placements on non-deleted boards. */
export type SortOption =
  | 'updated-desc'
  | 'created-desc'
  | 'completed-desc'
  | 'title-asc'
  | 'most-used-desc';

export interface TasksFiltersState {
  search: string;
  typeFilter: TypeFilter;
  statusFilter: StatusFilter;
  usageFilter: UsageFilter;
  sortBy: SortOption;
  /** Phase 6.Y — Timeboxed Tasks. Default false → tasks whose
   *  `endDate < now` are hidden from the list (the "zombie tasks"
   *  the user complained about). Toggle reveals them. Tasks with
   *  no `endDate` (indefinite) are always visible regardless. */
  showExpired: boolean;
  /** Issue #73 — When true (default), compound children that have no
   *  direct BoardTask placements of their own are removed from the top-
   *  level list; reach them by expanding their parent compound. Off = flat list. */
  groupByCompound: boolean;
}

export interface TasksFiltersApi extends TasksFiltersState {
  setSearch: (value: string) => void;
  setTypeFilter: (value: TypeFilter) => void;
  setStatusFilter: (value: StatusFilter) => void;
  setUsageFilter: (value: UsageFilter) => void;
  setSortBy: (value: SortOption) => void;
  setShowExpired: (value: boolean) => void;
  setGroupByCompound: (value: boolean) => void;
  /** Filtered + sorted task list ready to render. */
  filteredTasks: Task[];
  /** Per-task placement count on non-deleted boards (active OR completed
   *  OR draft). Exposed so the row can show "Placed on N boards". */
  placementCountByTaskId: Record<string, number>;
  /** Same as above but restricted to ACTIVE boards. Used by the usage
   *  filter's "on active boards" value and by the row's "active" hint. */
  activePlacementCountByTaskId: Record<string, number>;
  /** Issue #73 — Parent compound ids that should be auto-expanded because
   *  the current search query matches one of their non-independent children.
   *  Derived — not stored. */
  autoExpandCompoundIds: Set<string>;
  /** Draft-filtered task set (`computeBrowsableTasks` over
   *  `library.allTasks`) — the same set the Library segment browses.
   *  Exposed so other browse-only surfaces (e.g. the Pools segment's
   *  library-reuse picker, P2 I-2) can offer the same set without a
   *  second `computeBrowsableTasks` pass or duplicated live queries. NOT
   *  for resolution/chip-display use — those need the full `allTasks`
   *  set so a wizard-born task a pool already references still resolves. */
  browsableTasks: Task[];
}

const EMPTY_BOARD_TASKS = Object.freeze([]) as unknown as BoardTask[];
const EMPTY_BOARDS = Object.freeze([]) as unknown as Board[];

/**
 * Centralises the Tasks-tab filter + sort pipeline. Reads the library
 * from `useTaskLibrary` and the workspace-wide BoardTask / Board live
 * queries (small-N) to compute usage hints. The pipeline is pure: any
 * state change produces a fresh `filteredTasks` array via memo.
 */
export function useTasksFilters(library: TaskLibrary): TasksFiltersApi {
  const [search, setSearch] = useState('');
  const [typeFilter, setTypeFilter] = useState<TypeFilter>('all');
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('any');
  const [usageFilter, setUsageFilter] = useState<UsageFilter>('any');
  const [sortBy, setSortBy] = useState<SortOption>('updated-desc');
  const [showExpired, setShowExpired] = useState(false);
  // Issue #73 — group compound children under their parent by default.
  const [groupByCompound, setGroupByCompound] = useState(true);

  // Workspace-wide BoardTasks. `fetchAllBoardTasks` filters tombstoned
  // rows internally (docs/BOARD_INTEGRITY.md), so this already represents
  // the live placement set. Small-N — even very active users have well
  // under a few thousand placements. We need the `boardId` join to filter
  // by `Board.status` below.
  const allBoardTasks =
    useLiveQuery(() => fetchAllBoardTasks(), []) ?? EMPTY_BOARD_TASKS;
  const allBoards =
    useLiveQuery(() => fetchAllBoards(), []) ?? EMPTY_BOARDS;

  // Index boards by id so the join below stays O(N) total.
  const boardStatusById = useMemo(() => {
    const m: Record<string, BoardStatus> = {};
    for (const b of allBoards) m[b.id] = b.status;
    return m;
  }, [allBoards]);

  // Draft-visibility filter (mirrors iOS): hide wizard-born tasks that live
  // only on draft boards, or are orphaned (removed from the pool / board gone),
  // until they land on a live board. Reuses the board data loaded above.
  const browsableTasks = useMemo(
    () =>
      computeBrowsableTasks(
        library.allTasks,
        allBoardTasks,
        boardStatusById,
        library.childToParents,
      ),
    [library.allTasks, allBoardTasks, boardStatusById, library.childToParents],
  );

  const { placementCountByTaskId, activePlacementCountByTaskId } = useMemo(() => {
    // Count DISTINCT non-deleted boards per task (drafts included) — matching
    // the task-detail page (dedup by boardId + `!isDeleted` filter). Gating on
    // `boardStatusById` drops placements on soft-deleted boards; the Set dedups
    // duplicate rows on one board. Previously this counted every raw row incl.
    // rows on deleted boards, so the pool disagreed with task-detail.
    const allBoardsByTask: Record<string, Set<string>> = {};
    const activeBoardsByTask: Record<string, Set<string>> = {};
    for (const bt of allBoardTasks) {
      if (!boardStatusById[bt.boardId]) continue; // skip soft-deleted boards
      (allBoardsByTask[bt.taskId] ??= new Set<string>()).add(bt.boardId);
      if (boardStatusById[bt.boardId] === BoardStatus.ACTIVE) {
        // DISTINCT active boards too — the row's "N active" must match the
        // task-detail page (distinct active boards), not raw row count.
        (activeBoardsByTask[bt.taskId] ??= new Set<string>()).add(bt.boardId);
      }
    }
    const all: Record<string, number> = {};
    for (const [taskId, boardIds] of Object.entries(allBoardsByTask)) {
      all[taskId] = boardIds.size;
    }
    const active: Record<string, number> = {};
    for (const [taskId, boardIds] of Object.entries(activeBoardsByTask)) {
      active[taskId] = boardIds.size;
    }
    return { placementCountByTaskId: all, activePlacementCountByTaskId: active };
  }, [allBoardTasks, boardStatusById]);

  // Issue #73 — child task ids that have at least one BoardTask placement
  // of their own. These children are NOT suppressed from the top level even
  // when grouping is on (they appear at top level AND nested under each parent).
  const independentlyPlacedTaskIds = useMemo(() => {
    const ids = new Set<string>();
    for (const childId of library.childTaskIds) {
      if ((placementCountByTaskId[childId] ?? 0) > 0) {
        ids.add(childId);
      }
    }
    return ids;
  }, [library.childTaskIds, placementCountByTaskId]);

  // Issue #73 — when a search query matches a collapsed non-independent child's
  // title, include its parent compound ids here so the view auto-expands them.
  const autoExpandCompoundIds = useMemo<Set<string>>(() => {
    const trimmed = search.trim().toLowerCase();
    if (!trimmed || !groupByCompound) return new Set();
    const ids = new Set<string>();
    for (const [childId, parentIds] of Object.entries(library.childToParents)) {
      const child = library.taskMap[childId];
      if (!child) continue;
      // Only auto-expand for non-independent children (independent ones already
      // appear at top level so the user can already see them).
      if (
        !independentlyPlacedTaskIds.has(childId) &&
        child.title.toLowerCase().includes(trimmed)
      ) {
        for (const parentId of parentIds) {
          ids.add(parentId);
        }
      }
    }
    return ids;
  }, [search, groupByCompound, library.childToParents, library.taskMap, independentlyPlacedTaskIds]);

  const filteredTasks = useMemo(() => {
    const trimmed = search.trim().toLowerCase();
    // Browse the draft-filtered set: wizard-born tasks placed only on draft
    // boards (or orphaned) stay hidden until their board goes active.
    const typed = browsableTasks
      .filter((t) => matchesTypeFilter(t, typeFilter))
      .filter((t) => {
        // Issue #73 — suppress non-independent children from top level when on.
        // Children with placements of their own appear at top level AND nested.
        if (!groupByCompound) return true;
        if (!library.childTaskIds.has(t.id)) return true;
        return independentlyPlacedTaskIds.has(t.id);
      })
      .filter((t) => matchesSearch(t, trimmed))
      .filter((t) => matchesStatusFilter(t, library, statusFilter));
    const used = applyUsageFilter(
      typed,
      usageFilter,
      placementCountByTaskId,
      activePlacementCountByTaskId,
    );
    // Phase 6.Y — Default-hide expired timeboxed tasks unless the
    // user explicitly toggles them on. Indefinite tasks (no endDate)
    // are unaffected.
    const visible = showExpired ? used : used.filter((t) => !isTaskExpired(t));
    return visible
      .slice() // copy before sort so we don't mutate the memoized library
      .sort((a, b) => compareTasks(a, b, sortBy, placementCountByTaskId));
  }, [
    library,
    browsableTasks,
    search,
    typeFilter,
    statusFilter,
    showExpired,
    groupByCompound,
    independentlyPlacedTaskIds,
    usageFilter,
    sortBy,
    placementCountByTaskId,
    activePlacementCountByTaskId,
  ]);

  return {
    search,
    setSearch,
    typeFilter,
    setTypeFilter,
    statusFilter,
    setStatusFilter,
    usageFilter,
    setUsageFilter,
    sortBy,
    setSortBy,
    showExpired,
    setShowExpired,
    groupByCompound,
    setGroupByCompound,
    filteredTasks,
    placementCountByTaskId,
    activePlacementCountByTaskId,
    autoExpandCompoundIds,
    browsableTasks,
  };
}

// ─── Pure helpers (exported for testability and parity with iOS) ─────────────

export function matchesTypeFilter(task: Task, filter: TypeFilter): boolean {
  switch (filter) {
    case 'all':
      return true;
    case 'normal':
      return task.type === TaskType.NORMAL;
    case 'counting':
      return task.type === TaskType.COUNTING;
    case 'compound':
      // Matches ALL compound tasks — both ordered (formerly "progress")
      // and unordered (formerly "composite"). The isOrdered flag is an
      // internal implementation detail; users see a single "Compound" chip.
      return task.type === TaskType.COMPOUND;
    case 'achievement':
      return task.type === TaskType.ACHIEVEMENT;
  }
}

function matchesSearch(task: Task, trimmedLowerQuery: string): boolean {
  if (!trimmedLowerQuery) return true;
  if (task.title.toLowerCase().includes(trimmedLowerQuery)) return true;
  if (task.description?.toLowerCase().includes(trimmedLowerQuery)) return true;
  return false;
}

function matchesStatusFilter(
  task: Task,
  library: TaskLibrary,
  filter: StatusFilter,
): boolean {
  if (filter === 'any') return true;
  const inProgress = isInProgress(task, library);
  switch (filter) {
    case 'completed':
      return task.isCompleted === true;
    case 'in-progress':
      return !task.isCompleted && inProgress;
    case 'never-started':
      return !task.isCompleted && !inProgress;
  }
}

/**
 * "In progress" predicate. Counting tasks: any `currentCount > 0` and
 * not done. Compound tasks: at least one child Task is completed but
 * the compound parent isn't (we read child completion state out of
 * `library.taskMap`, which already has all the user's Tasks indexed).
 * Normal + Achievement tasks have no fractional state, so they're
 * either completed or never-started.
 */
export function isInProgress(task: Task, library: TaskLibrary): boolean {
  if (task.isCompleted) return false;
  if (task.type === TaskType.COUNTING) {
    return (task.currentCount ?? 0) > 0;
  }
  if (task.type === TaskType.COMPOUND) {
    const children = library.compoundChildrenByCompound[task.id] ?? [];
    for (const link of children) {
      const child = library.taskMap[link.childTaskId];
      if (child?.isCompleted) return true;
    }
    return false;
  }
  return false;
}

function compareTasks(
  a: Task,
  b: Task,
  sort: SortOption,
  placementCounts: Record<string, number>,
): number {
  switch (sort) {
    case 'title-asc':
      return a.title.localeCompare(b.title);
    case 'created-desc':
      return b.createdAt.localeCompare(a.createdAt);
    case 'updated-desc':
      return b.updatedAt.localeCompare(a.updatedAt);
    case 'completed-desc': {
      // Completed tasks first, sorted by completedAt desc; uncompleted
      // tasks fall to the bottom, ordered by updatedAt desc as a tie-
      // breaker so users still see recency.
      if (a.completedAt && b.completedAt) {
        return b.completedAt.localeCompare(a.completedAt);
      }
      if (a.completedAt) return -1;
      if (b.completedAt) return 1;
      return b.updatedAt.localeCompare(a.updatedAt);
    }
    case 'most-used-desc': {
      const ca = placementCounts[a.id] ?? 0;
      const cb = placementCounts[b.id] ?? 0;
      if (ca !== cb) return cb - ca;
      // Tie-break alphabetically so the list is stable.
      return a.title.localeCompare(b.title);
    }
  }
}

/**
 * Usage filter: depends on the placement count maps that the hook
 * derives from BoardTask + Board live queries. Lifted out of the hook
 * so the pipeline reads as one chain and the rule is unit-testable.
 */
export function applyUsageFilter(
  tasks: Task[],
  filter: UsageFilter,
  placementCountByTaskId: Record<string, number>,
  activePlacementCountByTaskId: Record<string, number>,
): Task[] {
  switch (filter) {
    case 'any':
      return tasks;
    case 'unused':
      return tasks.filter((t) => (placementCountByTaskId[t.id] ?? 0) === 0);
    case 'on-active-boards':
      return tasks.filter((t) => (activePlacementCountByTaskId[t.id] ?? 0) > 0);
  }
}
