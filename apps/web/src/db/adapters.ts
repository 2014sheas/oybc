import {
  TaskType,
  deriveDisplayedCount,
  evaluateCompound,
  isEventOwningTask,
  resolveTaskWindowState,
  type Task,
  type TaskEvent,
  type CompoundChild,
  type CellState,
} from '@oybc/shared';
import type { TaskSquareData, SquareState } from '../components/interactiveTaskSquareUtils';

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §Semantics): the per-square
 * window context threaded into {@link taskToSquareState}. When present, primitive
 * (normal / plain-counting) squares resolve against the board's window via
 * TaskEvents instead of the lifetime `isCompleted` / `currentCount` caches;
 * compound squares inherit the window; derived (shared-counter-linked) counters
 * stay on their cache (the carve-out). When absent, behavior is byte-identical
 * to the pre-Windowed-Completion lifetime read (library surfaces, tests).
 */
export interface SquareWindowContext {
  /** Window lower bound (`board.startDate`). */
  windowStart: string;
  /** This workspace's non-deleted TaskEvents grouped by `taskId`. */
  eventsByTaskId: Record<string, TaskEvent[]>;
}

/**
 * Builds a {@link SquareWindowContext} from a flat TaskEvent list + a board's
 * window start. Pure grouping/filter logic factored out of the read-model
 * hooks so every board-square surface (BoardPlaySurface's `useBoardPlayData`,
 * `RisoBoard`'s mini-poster, the edit-mode rearrange preview) derives the
 * SAME context from the SAME live-query result via `useSquareWindowContext`
 * (`hooks/useSquareWindowContext.ts`) instead of re-deriving it — or, worse,
 * omitting it — ad hoc per surface (docs/WINDOWED_COMPLETION.md §Task caches:
 * "Board grids ... stop reading them for anything windowed").
 *
 * @param events - All TaskEvents in scope (a live-query snapshot is fine; deleted rows are filtered here).
 * @param windowStart - The board's window lower bound (`board.startDate`).
 */
export function buildSquareWindowContext(
  events: TaskEvent[],
  windowStart: string,
): SquareWindowContext {
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) {
    if (e.isDeleted) continue;
    (eventsByTaskId[e.taskId] ??= []).push(e);
  }
  return { windowStart, eventsByTaskId };
}

/**
 * Converts a Task record to the TaskSquareData shape expected by
 * InteractiveTaskSquare.
 *
 * For compound tasks, pass `compoundChildren` (the pre-resolved children for
 * this specific task) and `taskMap` so the children's completion states can be
 * evaluated.
 *
 * @param task - The Task record to adapt
 * @param compoundChildren - Compound tasks only: pre-resolved CompoundChild links for this task
 * @param taskMap - Compound tasks only: id → Task lookup for child resolution
 * @param childrenByCompound - Compound tasks only: full map used for recursive evaluateCompound
 * @param windowContext - Windowed Completion context for primitive/compound resolution
 * @returns TaskSquareData suitable for InteractiveTaskSquare
 */
export function taskToSquareData(
  task: Task,
  compoundChildren?: CompoundChild[],
  taskMap?: Record<string, Task>,
  childrenByCompound?: Record<string, CompoundChild[]>,
  windowContext?: SquareWindowContext,
): TaskSquareData {
  // Board-integrity PR-3 (issue #360, finding 2) — ACHIEVEMENT squares are
  // read-only on the grid; their completion derives from the watched
  // board/template via the kernel (surfaced through `taskToSquareState`'s
  // `cellState` param below), never a local toggle. This adapter just tags
  // the square's TYPE so the render layer stops treating it as a normal
  // toggle target (the bug: falling through to the NORMAL/COUNTING branch
  // below, which reads a lifetime cache never written for achievement
  // tasks).
  if (task.type === TaskType.ACHIEVEMENT) {
    return {
      id: task.id,
      title: task.title,
      type: 'achievement',
    };
  }

  if (task.type === TaskType.COMPOUND) {
    const links = compoundChildren ?? [];
    const map = taskMap ?? {};
    const cbMap = childrenByCompound ?? {};
    // Windowed Completion: resolve each child row's checkmark against the host
    // board's window so the compound detail sheet agrees with the (windowed)
    // grid square. Derived-counting children stay on their cache (carve-out).
    const compoundCtx = windowContext
      ? { windowStart: windowContext.windowStart, eventsByTaskId: windowContext.eventsByTaskId }
      : undefined;
    const resolveChild = (childTask: Task): boolean => {
      if (childTask.type === TaskType.COMPOUND) {
        return evaluateCompound(childTask, cbMap, map, compoundCtx);
      }
      if (windowContext && isEventOwningTask(childTask)) {
        const evts = windowContext.eventsByTaskId[childTask.id] ?? [];
        return resolveTaskWindowState(childTask, evts, windowContext.windowStart).isCompleted;
      }
      return childTask.isCompleted;
    };
    const children = links.map((link) => {
      const childTask = map[link.childTaskId];
      if (!childTask) return { taskId: link.childTaskId, title: '<missing>', isCompleted: false };
      return { taskId: link.childTaskId, title: childTask.title, isCompleted: resolveChild(childTask) };
    });

    return {
      id: task.id,
      title: task.title,
      type: 'compound',
      operator: task.operator ?? undefined,
      threshold: task.threshold ?? undefined,
      children,
    };
  }

  // Post-unification: only NORMAL / COUNTING reach this branch (compound
  // is handled above). The legacy 'progress' SquareData type is dead — its
  // role is taken by 'compound'.
  const type = task.type === TaskType.COUNTING ? 'counting' : 'normal';

  return {
    id: task.id,
    title: task.title,
    type,
    action: task.action ?? undefined,
    maxCount: task.maxCount ?? undefined,
    unit: task.unit ?? undefined,
    // Phase 3 — Shared Counters: map link fields so the render layer can
    // (a) baseline-adjust the displayed count via `deriveDisplayedCount`,
    // and (b) gate decrement/reset actions for linked derived counters.
    sharedCounterId: task.sharedCounterId ?? undefined,
    baseline: task.baseline ?? undefined,
  };
}

/**
 * Derives the SquareState for a task square from the underlying Task record.
 *
 * Under the unified compound model, BoardTask is placement-only. When
 * `windowContext` is supplied (every board surface), primitive and compound
 * state resolve **windowed** against `task_events` for that board's window —
 * the Task row's lifetime caches are read only for the derived shared-counter
 * carve-out, or as the no-context fallback (library/legacy callers). See
 * docs/WINDOWED_COMPLETION.md §Task caches. Progress-step completion
 * (completedStepIds) is no longer tracked per-board — returns an empty Set
 * for non-compound tasks.
 *
 * For compound tasks, pass `compoundChildren` and `taskMap` so the operator-
 * aware completion can be evaluated via `evaluateCompound`.
 *
 * @param task - The Task record whose state to adapt
 * @param compoundChildren - Compound tasks only: pre-resolved links for this task
 * @param taskMap - Compound tasks only: id → Task lookup
 * @param childrenByCompound - Compound tasks only: full map for recursive evaluation
 * @param windowContext - Windowed Completion context for primitive/compound resolution
 * @param cellState - Board-integrity PR-3 (issue #360): the kernel's per-cell
 *   resolution for THIS BoardTask placement (`computeBoardGrid`'s `cells[]`,
 *   keyed by boardTaskId at the call site). Consulted ONLY for
 *   ACHIEVEMENT-typed tasks — the adapter has no cross-board context of its
 *   own to resolve "is the watched board/template met" locally. Every other
 *   branch is unchanged (byte-identical resolution to pre-PR-3).
 * @returns SquareState suitable for InteractiveTaskSquare
 */
export function taskToSquareState(
  task: Task,
  _compoundChildren?: CompoundChild[],
  taskMap?: Record<string, Task>,
  childrenByCompound?: Record<string, CompoundChild[]>,
  windowContext?: SquareWindowContext,
  cellState?: CellState,
): SquareState {
  // Board-integrity PR-3 (issue #360, finding 2) — ACHIEVEMENT squares read
  // their completion from the kernel's per-cell resolution, never a lifetime
  // cache (none is ever written for achievement tasks — that was the bug:
  // this branch didn't exist, so achievement tasks fell through to the
  // plain-task branch below and always read `task.isCompleted` = false/stale).
  if (task.type === TaskType.ACHIEVEMENT) {
    return {
      isCompleted: cellState?.isCompleted ?? false,
      currentCount: 0,
      completedStepIds: new Set<string>(),
    };
  }

  if (task.type === TaskType.COMPOUND) {
    const cbMap = childrenByCompound ?? {};
    const map = taskMap ?? {};
    // Windowed Completion: thread the host board's window so primitive
    // children resolve against events (nested compounds inherit it).
    const compoundCtx = windowContext
      ? { windowStart: windowContext.windowStart, eventsByTaskId: windowContext.eventsByTaskId }
      : undefined;
    return {
      isCompleted: evaluateCompound(task, cbMap, map, compoundCtx),
      currentCount: 0,
      completedStepIds: new Set<string>(),
    };
  }

  // Phase 3 — Shared Counters: linked tasks store the source's raw
  // `currentCount` as a mirrored accumulator. The UI must display the
  // baseline-adjusted derived value, not the raw source total. Apply
  // `deriveDisplayedCount` here so every consumer of `SquareState`
  // (grid squares, DetailModal, FloatingContextMenu, progress bar)
  // automatically sees the correct derived count without a second call.
  //
  // Windowed Completion carve-out (docs §Derived-task carve-out): derived
  // counters stay on their propagation-stamped lifetime cache — NOT windowed.
  if (task.sharedCounterId != null) {
    const { displayed } = deriveDisplayedCount(
      { baseline: task.baseline ?? 0, maxCount: task.maxCount ?? 0 },
      { currentCount: task.currentCount ?? 0 },
    );
    return {
      isCompleted: task.isCompleted,
      currentCount: displayed,
      completedStepIds: new Set<string>(),
    };
  }

  // Windowed Completion (docs §Semantics): a plain normal / counting square on
  // a board resolves against the board's window via events, not the lifetime
  // cache — this is what stops a completed task bleeding green into a fresh
  // window's board. Falls back to the lifetime cache when no window context is
  // supplied (library surfaces / legacy callers).
  if (windowContext && isEventOwningTask(task)) {
    const events = windowContext.eventsByTaskId[task.id] ?? [];
    const { isCompleted, count } = resolveTaskWindowState(task, events, windowContext.windowStart);
    return {
      isCompleted,
      currentCount: count,
      completedStepIds: new Set<string>(),
    };
  }

  return {
    isCompleted: task.isCompleted,
    currentCount: task.currentCount ?? 0,
    // Per-board step completion is not tracked under the unified model.
    completedStepIds: new Set<string>(),
  };
}
