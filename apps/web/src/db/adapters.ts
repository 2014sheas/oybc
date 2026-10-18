import {
  TaskType,
  evaluateCompound,
  isEventOwningTask,
  resolveDerivedCounterWindowState,
  resolveFamilyCountKind,
  resolveLinkedCounterDisplay,
  resolveTaskWindowState,
  type Task,
  type TaskEvent,
  type CompoundChild,
  type CellState,
  withPlacementParams,
  withChildTarget,
  type PlacementChildTarget,
  type BoardTask,
} from '@oybc/shared';
import type { CompoundChildCount, SquareTaskType, TaskSquareData, SquareState } from '../components/interactiveTaskSquareUtils';

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §Semantics): the per-square
 * window context threaded into {@link taskToSquareState}. When present, primitive
 * (normal / plain-counting) squares resolve against the board's window via
 * TaskEvents instead of the lifetime `isCompleted` / `currentCount` caches;
 * compound squares inherit the window; linked counters resolve from their
 * ROOT's events over the host window (`resolveLinkedCounterDisplay`, the same
 * rule the kernel uses). When absent, plain tasks read their lifetime caches
 * (library surfaces, tests) and a linked counter reads its root's lifetime
 * events.
 *
 * The window is `[windowStart, windowEnd]`, inclusive at both ends (2026-09-24
 * amendment of WC Decision 1): an ended board's squares ignore events logged
 * after its `endDate`, so a later window's logs never raise its counts.
 */
export interface SquareWindowContext {
  /** Window lower bound (`board.startDate`). */
  windowStart: string;
  /**
   * Window INCLUSIVE upper bound (`board.endDate`, via `boardWindowEnd`), or
   * `null` for an open-ended window (indefinite boards). Required so every
   * construction site states the bound explicitly.
   */
  windowEnd: string | null;
  /**
   * The board's `sealedAt` when it is closed (slice 0): a linked row's
   * display drops root events after the seal, exactly as the sealed
   * re-derive does — iOS passes `board?.sealedAt` everywhere, web did not.
   */
  sealedAt?: string | null;
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
 * @param windowEnd - The board's inclusive window upper bound (`board.endDate`),
 *   or `null` for an open-ended (indefinite) board.
 * @returns The grouped events plus the window bounds.
 */
export function buildSquareWindowContext(
  events: TaskEvent[],
  windowStart: string,
  windowEnd: string | null,
): SquareWindowContext {
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) {
    if (e.isDeleted) continue;
    (eventsByTaskId[e.taskId] ??= []).push(e);
  }
  return { windowStart, windowEnd, eventsByTaskId };
}

/**
 * Whether a compound's CHILD reads complete on a board — exactly the checkmark
 * the compound detail sheet paints (and the kernel's `resolvePrimitiveChildState`
 * order): nested compounds evaluate against the host window; linked
 * counters resolve from their root's events over the host window;
 * event-owning children resolve against the host board's
 * `[windowStart, windowEnd]`; every child reads its lifetime cache when
 * no window context is given.
 *
 * @param childTask - The child task to resolve.
 * @param taskMap - id → Task lookup (nested compound children resolve through it).
 * @param childrenByCompound - Full compound → children map for nested evaluation.
 * @param windowContext - The host board's window context, if any.
 * @returns `true` iff the child is complete in the host board's window.
 */
export function resolveCompoundChildCompleted(
  childTask: Task,
  taskMap: Record<string, Task>,
  childrenByCompound: Record<string, CompoundChild[]>,
  windowContext?: SquareWindowContext,
): boolean {
  if (childTask.type === TaskType.COMPOUND) {
    const compoundCtx = windowContext
      ? {
          windowStart: windowContext.windowStart,
          windowEnd: windowContext.windowEnd,
          eventsByTaskId: windowContext.eventsByTaskId,
        }
      : undefined;
    return evaluateCompound(childTask, childrenByCompound, taskMap, compoundCtx);
  }
  const derived = windowContext
    ? resolveDerivedCounterWindowState(childTask, windowContext.eventsByTaskId, windowContext)
    : null;
  if (derived) return derived.isCompleted;
  if (windowContext && isEventOwningTask(childTask)) {
    const evts = windowContext.eventsByTaskId[childTask.id] ?? [];
    return resolveTaskWindowState(childTask, evts, windowContext.windowStart, windowContext.windowEnd)
      .isCompleted;
  }
  return childTask.isCompleted;
}

/**
 * The desired completed state for a tap on a compound child in a board's
 * detail sheet: the inverse of what the sheet shows
 * ({@link resolveCompoundChildCompleted}), never the lifetime latch. On an
 * ended board the two differ (a completion logged today on the next window's
 * board sets the latch but is outside this board's window), and toggling off
 * the latch would un-complete a child the sheet shows incomplete — or delete
 * another window's completion.
 *
 * @param childTask - The tapped child.
 * @param taskMap - id → Task lookup.
 * @param childrenByCompound - Full compound → children map.
 * @param windowContext - The host board's window context.
 * @returns The state the tap should set.
 */
export function compoundChildToggleDesired(
  childTask: Task,
  taskMap: Record<string, Task>,
  childrenByCompound: Record<string, CompoundChild[]>,
  windowContext: SquareWindowContext,
): boolean {
  return !resolveCompoundChildCompleted(childTask, taskMap, childrenByCompound, windowContext);
}

/**
 * A counting child's count for the compound square sheet's checklist row: the
 * same windowed read the checkmark uses — a linked child reads its counter's
 * in-window total (`resolveLinkedCounterDisplay`), an event-owning child its
 * own events in the host window — and the amount a tap logs: a linked child
 * steps by its counter's default log amount, a plain one by 1.
 *
 * @param childTask - The child task.
 * @param taskMap - id → Task lookup (the counter root's default amount / kind).
 * @param windowContext - The host board's window context, if any.
 * @returns The count model, or `undefined` for a non-counting child.
 */
export function compoundChildCount(
  childTask: Task,
  taskMap: Record<string, Task>,
  windowContext?: SquareWindowContext,
): CompoundChildCount | undefined {
  if (childTask.type !== TaskType.COUNTING) return undefined;
  // The counter the step logs on: a linked child's root, or the child itself
  // when it IS a counter root (hub counter, or linked to by another live task)
  // — iOS `BoardPlayViewModel.sharedCounterSourceId(for:)`.
  const isRoot =
    childTask.isCounter === true ||
    Object.values(taskMap).some((t) => t.sharedCounterId === childTask.id && !t.isDeleted);
  const rootId = childTask.sharedCounterId ?? (isRoot ? childTask.id : undefined);
  const root = rootId ? taskMap[rootId] : undefined;
  let current: number;
  if (childTask.sharedCounterId) {
    current = resolveLinkedCounterDisplay(
      childTask,
      windowContext?.eventsByTaskId,
      windowContext?.sealedAt ?? undefined,
      windowContext ? { startDate: windowContext.windowStart, endDate: windowContext.windowEnd } : undefined,
    ).displayed;
  } else if (windowContext && isEventOwningTask(childTask)) {
    const evts = windowContext.eventsByTaskId[childTask.id] ?? [];
    current = resolveTaskWindowState(childTask, evts, windowContext.windowStart, windowContext.windowEnd).count;
  } else {
    current = childTask.currentCount ?? 0;
  }
  return {
    current,
    max: childTask.maxCount ?? 0,
    unit: childTask.unit ?? '',
    kind: resolveFamilyCountKind(childTask, (id) => taskMap[id]),
    step: root?.defaultLogAmount ?? 1,
  };
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
/**
 * The placement-adjusted task a board surface renders for `bt` (slice 2a):
 * `withPlacementParams` with the root's title settings for a linked task.
 * `undefined` when the task is missing from the map.
 *
 * @param bt - The placement.
 * @param taskMap - The workspace tasks by id.
 * @returns The task to render, or `undefined`.
 */
export function placedTaskFor(bt: Pick<BoardTask, 'taskId'> & Partial<BoardTask>, taskMap: Record<string, Task>): Task | undefined {
  const task = taskMap[bt.taskId];
  if (!task) return undefined;
  const root = task.sharedCounterId ? taskMap[task.sharedCounterId] : undefined;
  return withPlacementParams(task, bt, root ?? null);
}

export function taskToSquareData(
  task: Task,
  compoundChildren?: CompoundChild[],
  taskMap?: Record<string, Task>,
  childrenByCompound?: Record<string, CompoundChild[]>,
  windowContext?: SquareWindowContext,
  /** The compound placement's per-child goals (slice 2a), direct children only. */
  childTargets?: PlacementChildTarget[] | null,
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
    // grid square. Window-stamped derived children resolve from their root's
    // events in their own window — the kernel's `resolvePrimitiveChildState`
    // order — and only hub-linked derived children stay on their cache.
    const resolveChild = (childTask: Task): boolean =>
      resolveCompoundChildCompleted(childTask, map, cbMap, windowContext);
    const children = links.map((link) => {
      const rawChild = map[link.childTaskId];
      if (!rawChild) return { taskId: link.childTaskId, title: '<missing>', isCompleted: false };
      const childTask = withChildTarget(rawChild, childTargets);
      const count = compoundChildCount(childTask, map, windowContext);
      return { taskId: link.childTaskId, title: childTask.title, isCompleted: resolveChild(childTask), taskType: childTask.type as SquareTaskType, ...(count ? { count } : {}) };
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
    // Counter kinds — a linked row follows its root's kind (D5).
    ...(type === 'counting' ? { countKind: resolveFamilyCountKind(task, (id) => taskMap?.[id]) } : {}),
    // Phase 3 — Shared Counters: map link fields so the render layer can
    // (a) derive the displayed count via `resolveLinkedCounterDisplay`,
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
 * the Task row's lifetime caches are read only as the no-context fallback
 * (legacy callers; a linked counter reads its root's lifetime events). See
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
  /** The compound placement's per-child goals (slice 2a), direct children only. */
  childTargets?: PlacementChildTarget[] | null,
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
      ? {
          windowStart: windowContext.windowStart,
          windowEnd: windowContext.windowEnd,
          eventsByTaskId: windowContext.eventsByTaskId,
        }
      : undefined;
    return {
      isCompleted: evaluateCompound(task, cbMap, map, compoundCtx, childTargets),
      currentCount: 0,
      completedStepIds: new Set<string>(),
    };
  }

  // Shared Counters — a linked (derived) counting square. `resolveLinkedCounterDisplay`
  // is the single display rule (docs §Derived-task carve-out, amended
  // 2026-09-23), so every consumer of `SquareState` (grid squares,
  // square sheet, FloatingContextMenu, progress bar) sees the same thing:
  //   - WINDOW-STAMPED rows: count AND completion are the ROOT's increment sum
  //     inside the row's own `[startDate, endDate]` — the same function the
  //     derivation kernel resolves the cell with, so a cell can never paint
  //     green (or read N/N) while board stats count it incomplete. The
  //     one-way latch is not read.
  //   - HUB-LINKED rows (no window stamp) WITH a window context: the root's
  //     increment sum inside THIS board's window (owner rule 2026-10-01).
  //   - No window context: the ROOT's lifetime event sum — and 0 without an
  //     event map (every production board surface passes a context; the
  //     library reads `contextlessCounterState` itself). Neither baseline nor
  //     the latch is read.
  if (task.sharedCounterId != null) {
    // A non-window-stamped linked row resolves over THIS board's window too
    // (owner rule 2026-10-01).
    const { displayed, isCompleted } = resolveLinkedCounterDisplay(
      task,
      windowContext?.eventsByTaskId,
      windowContext?.sealedAt ?? undefined,
      windowContext ? { startDate: windowContext.windowStart, endDate: windowContext.windowEnd } : null,
    );
    return {
      isCompleted,
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
    const { isCompleted, count } = resolveTaskWindowState(
      task,
      events,
      windowContext.windowStart,
      windowContext.windowEnd,
    );
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
 * Board Edit redesign slice 4 (D16) — what a COUNTING square SHOWS on a
 * CLOSED board: the sealed-bounded windowed count (`[startDate, min(endDate,
 * sealedAt)]`), not the old max/0 snapshot display and not the lifetime
 * cache, so a partial late log is visible ("3/5", not just green/grey).
 * Mirrors the sealing data layer's `boundWindowContextAtSeal` +
 * `resolveTaskWindowState` / `resolveWindowStampedDerivedState` pattern —
 * same bound, so the count and the frozen `sealedCompletedCells` green can
 * never disagree — but synchronous, built from an already-loaded event map
 * (`SquareWindowContext.eventsByTaskId`) for render-time use.
 *
 * A hub-linked linked row (no window stamp) shows the root's sealed-bounded
 * sum over the board's own window (owner rule 2026-10-01) — no lifetime read.
 *
 * @param task           The COUNTING task (or window-stamped derived row).
 * @param eventsByTaskId The workspace's non-deleted events grouped by taskId.
 * @param board          Only `startDate` / `endDate` / `sealedAt` are read.
 */
export function resolveClosedBoardCounterDisplay(
  task: Task,
  eventsByTaskId: Record<string, TaskEvent[]>,
  board: { startDate: string; endDate?: string | null; sealedAt?: string | null },
): { displayed: number; isCompleted: boolean } {
  // Display = kernel (slice 0): a linked row is exactly what the live cell
  // shows, bounded at the seal; this used to be a fourth hand-rolled copy of
  // the in-window sum.
  if (task.sharedCounterId != null) {
    return resolveLinkedCounterDisplay(task, eventsByTaskId, board.sealedAt ?? undefined, {
      startDate: board.startDate,
      endDate: board.endDate ?? null,
    });
  }
  const ownEvents = (eventsByTaskId[task.id] ?? []).filter((e) => !e.isDeleted);
  const sealedMs = board.sealedAt ? new Date(board.sealedAt).getTime() : NaN;
  const bounded = Number.isNaN(sealedMs)
    ? ownEvents
    : ownEvents.filter((e) => new Date(e.occurredAt).getTime() <= sealedMs);
  const { count, isCompleted } = resolveTaskWindowState(task, bounded, board.startDate, board.endDate ?? null);
  return { displayed: count, isCompleted };
}
