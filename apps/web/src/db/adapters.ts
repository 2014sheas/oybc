import {
  TaskType,
  deriveDisplayedCount,
  evaluateCompound,
  isEventOwningTask,
  resolveTaskWindowState,
  type Task,
  type TaskStep,
  type TaskEvent,
  type CompoundChild,
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
 * Converts a Task record (and its associated TaskStep records) to the
 * TaskSquareData shape expected by InteractiveTaskSquare.
 *
 * For compound tasks, pass `compoundChildren` (the pre-resolved children for
 * this specific task) and `taskMap` so the children's completion states can be
 * evaluated.
 *
 * @param task - The Task record to adapt
 * @param taskSteps - All task steps; filtered internally by task ID (used for legacy progress rows)
 * @param compoundChildren - Compound tasks only: pre-resolved CompoundChild links for this task
 * @param taskMap - Compound tasks only: id → Task lookup for child resolution
 * @param childrenByCompound - Compound tasks only: full map used for recursive evaluateCompound
 * @returns TaskSquareData suitable for InteractiveTaskSquare
 */
export function taskToSquareData(
  task: Task,
  taskSteps: TaskStep[],
  compoundChildren?: CompoundChild[],
  taskMap?: Record<string, Task>,
  childrenByCompound?: Record<string, CompoundChild[]>,
  windowContext?: SquareWindowContext,
): TaskSquareData {
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
      isOrdered: task.isOrdered ?? undefined,
      children,
    };
  }

  // Post-unification: only NORMAL / COUNTING reach this branch (compound
  // is handled above). The legacy 'progress' SquareData type is dead — its
  // role is taken by 'compound' with isOrdered=true.
  const type = task.type === TaskType.COUNTING ? 'counting' : 'normal';

  // `taskSteps` is intentionally unused in the post-unification path; the
  // legacy progress branch consumed it. Kept as a parameter so call sites
  // don't need to change all at once. Will be removed in a follow-up sweep.
  void taskSteps;

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
 * Under the unified compound model, BoardTask is placement-only. Completion
 * state (isCompleted, currentCount) lives globally on Task. Progress-step
 * completion (completedStepIds) is no longer tracked per-board — returns an
 * empty Set for non-compound tasks.
 *
 * For compound tasks, pass `compoundChildren` and `taskMap` so the operator-
 * aware completion can be evaluated via `evaluateCompound`.
 *
 * @param task - The Task record whose state to adapt
 * @param compoundChildren - Compound tasks only: pre-resolved links for this task
 * @param taskMap - Compound tasks only: id → Task lookup
 * @param childrenByCompound - Compound tasks only: full map for recursive evaluation
 * @returns SquareState suitable for InteractiveTaskSquare
 */
export function taskToSquareState(
  task: Task,
  _compoundChildren?: CompoundChild[],
  taskMap?: Record<string, Task>,
  childrenByCompound?: Record<string, CompoundChild[]>,
  windowContext?: SquareWindowContext,
): SquareState {
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

/**
 * @deprecated Use `taskToSquareState` instead.
 * Kept for backward compatibility with callers outside the three Task 4.4
 * files; will be removed once playground files are migrated in Task 4.5.
 */
export const boardTaskToSquareState = taskToSquareState;
