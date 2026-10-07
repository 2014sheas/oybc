import { describe, expect, it } from 'vitest';
import { TaskType, type CellState, type Task, type TaskEvent } from '@oybc/shared';
import {
  buildSquareWindowContext,
  resolveClosedBoardCounterDisplay,
  taskToSquareData,
  taskToSquareState,
} from '../adapters';

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §Task caches) — review
 * finding: `RisoBoard` (the Home mini-poster) and `useBoardPlay`'s edit-mode
 * rearrange preview were still calling `taskToSquareState` with NO window
 * context, so a lifetime-complete task bled green (+ phantom bingo rings) on a
 * freshly-spawned/reused board even though the real BoardPlaySurface grid was
 * correctly grey. Both surfaces were fixed to build their window context via
 * the shared `useSquareWindowContext` hook, which wraps `buildSquareWindowContext`
 * — this suite covers that pure builder plus the exact `taskToSquareState` call
 * shape both surfaces use (mirrors the regression test in
 * `db/operations/__tests__/spawnRollover.test.ts`, but exercises the shared
 * builder rather than hand-rolling the grouping inline).
 */

const WINDOW_START = '2026-05-06T00:00:00.000Z'; // fresh window (e.g. a new daily board)
const PRIOR_COMPLETION = '2026-05-05T12:00:00.000Z'; // yesterday's greenlog

function makeLifetimeCompleteTask(id: string): Task {
  return {
    id,
    userId: 'user-1',
    title: 'Morning workout',
    type: TaskType.NORMAL,
    // The lifetime cache says COMPLETE — exactly the stale bit a
    // no-window-context call would read.
    isCompleted: true,
    completedAt: PRIOR_COMPLETION,
    totalCompletions: 1,
    totalInstances: 1,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: PRIOR_COMPLETION,
    version: 2,
    isDeleted: false,
  };
}

function makePriorCompletionEvent(taskId: string): TaskEvent {
  return {
    id: `evt-${taskId}`,
    userId: 'user-1',
    taskId,
    kind: 'completion',
    occurredAt: PRIOR_COMPLETION, // BEFORE the fresh window
    createdAt: PRIOR_COMPLETION,
    updatedAt: PRIOR_COMPLETION,
    version: 1,
    isDeleted: false,
  };
}

describe('buildSquareWindowContext', () => {
  it('groups non-deleted events by taskId and drops deleted (tombstoned) events', () => {
    const events: TaskEvent[] = [
      makePriorCompletionEvent('task-a'),
      { ...makePriorCompletionEvent('task-a'), id: 'evt-task-a-2', occurredAt: '2026-05-06T09:00:00.000Z' },
      { ...makePriorCompletionEvent('task-b'), isDeleted: true },
    ];

    const ctx = buildSquareWindowContext(events, WINDOW_START, null);

    expect(ctx.windowStart).toBe(WINDOW_START);
    expect(ctx.eventsByTaskId['task-a']).toHaveLength(2);
    expect(ctx.eventsByTaskId['task-b']).toBeUndefined();
  });

  it('returns an empty grouping for an empty event list', () => {
    const ctx = buildSquareWindowContext([], WINDOW_START, null);
    expect(ctx.eventsByTaskId).toEqual({});
  });
});

describe('mini-poster data path (RisoBoard + rearrange-preview regression)', () => {
  it('a lifetime-complete task with only a pre-window completion event resolves windowed-grey', () => {
    const task = makeLifetimeCompleteTask('task-a');
    const events = [makePriorCompletionEvent('task-a')];
    const windowContext = buildSquareWindowContext(events, WINDOW_START, null);

    // Sanity: the lifetime cache itself is still (correctly) complete —
    // library/Tasks-tab surfaces should keep showing this green.
    expect(task.isCompleted).toBe(true);

    // The exact call shape RisoBoard's cell useMemo and useBoardPlay's
    // arrangeSlots useMemo both make: taskMap/compoundChildrenByCompound are
    // irrelevant for a NORMAL task, windowContext is the fix under test.
    const squareState = taskToSquareState(task, undefined, { [task.id]: task }, {}, windowContext);

    expect(squareState.isCompleted).toBe(false);
  });

  it('the same task resolves windowed-complete once an event lands inside the new window', () => {
    const task = makeLifetimeCompleteTask('task-a');
    const events = [
      makePriorCompletionEvent('task-a'),
      {
        ...makePriorCompletionEvent('task-a'),
        id: 'evt-task-a-new',
        occurredAt: '2026-05-06T09:00:00.000Z', // inside the new window
      },
    ];
    const windowContext = buildSquareWindowContext(events, WINDOW_START, null);

    const squareState = taskToSquareState(task, undefined, { [task.id]: task }, {}, windowContext);

    expect(squareState.isCompleted).toBe(true);
  });

  it('omitting the window context (the pre-fix bug) falls back to the lifetime cache and bleeds green', () => {
    const task = makeLifetimeCompleteTask('task-a');

    // No windowContext argument at all — reproduces exactly what RisoRoard's
    // `taskToSquareState(task, undefined, taskMap, compoundChildrenByCompound)`
    // (no 5th arg) used to do before this fix.
    const squareState = taskToSquareState(task, undefined, { [task.id]: task }, {});

    expect(squareState.isCompleted).toBe(true);
  });
});

/**
 * Board-integrity PR-3 (issue #360, finding 2) — "Web achievement render
 * bug": before this branch existed, an ACHIEVEMENT-typed Task fell through
 * `taskToSquareData`'s normal/counting else-branch (rendering as a plain
 * 'normal' square) and `taskToSquareState`'s plain-task branch (reading
 * `task.isCompleted`, a lifetime cache never written for achievement
 * tasks — so always `false`/stale). A tap on the grid then ran the
 * NORMAL-task completion write path (`handleComplete`'s `isCompleted`
 * toggle), which could even auto-activate a DRAFT board. This suite covers
 * the fix: `taskToSquareData` now tags the square TYPE, and
 * `taskToSquareState` resolves `isCompleted` from the kernel's per-cell
 * `CellState` (there is no cross-board context to resolve it locally).
 */
describe('ACHIEVEMENT branch (board-integrity PR-3, issue #360)', () => {
  function makeAchievementTask(over: Partial<Task> = {}): Task {
    return {
      id: 'ach-1',
      userId: 'user-1',
      title: 'Finish the monthly',
      type: TaskType.ACHIEVEMENT,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 1,
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
      ...over,
    };
  }

  it('taskToSquareData tags the square as type "achievement", not "normal"', () => {
    const task = makeAchievementTask();
    const squareData = taskToSquareData(task);
    expect(squareData.type).toBe('achievement');
  });

  it('taskToSquareState resolves isCompleted from the kernel CellState, not task.isCompleted', () => {
    const task = makeAchievementTask({ isCompleted: false }); // lifetime cache is stale-false
    const cellState: CellState = {
      boardTaskId: 'bt-1',
      taskId: task.id,
      row: 0,
      col: 0,
      idx: 0,
      isCompleted: true, // the kernel says the watched board IS met
      achievement: {
        mode: 'specificBoard',
        referencedBoardId: 'watched-board',
        referencedBoardCompleted: true,
      },
    };

    const squareState = taskToSquareState(task, undefined, { [task.id]: task }, {}, undefined, cellState);

    expect(squareState.isCompleted).toBe(true);
  });

  it('taskToSquareState degrades to incomplete when no CellState is supplied (never crashes, never trusts the stale cache)', () => {
    const task = makeAchievementTask({ isCompleted: true }); // even if the cache WERE true, the kernel is authoritative
    const squareState = taskToSquareState(task, undefined, { [task.id]: task }, {});
    expect(squareState.isCompleted).toBe(false);
  });

  it('an achievement square never reports counting/progress-step state', () => {
    const task = makeAchievementTask();
    const cellState: CellState = {
      boardTaskId: 'bt-1',
      taskId: task.id,
      row: 0,
      col: 0,
      idx: 0,
      isCompleted: true,
    };
    const squareState = taskToSquareState(task, undefined, { [task.id]: task }, {}, undefined, cellState);
    expect(squareState.currentCount).toBe(0);
    expect(squareState.completedStepIds.size).toBe(0);
  });
});

describe('resolveClosedBoardCounterDisplay (Board Edit redesign slice 4, D16)', () => {
  const BOARD = {
    startDate: '2026-07-01T00:00:00.000Z',
    endDate: '2026-07-01T23:59:59.999Z',
    sealedAt: '2026-07-02T00:00:01.000Z',
  };

  function counter(id: string, maxCount: number, over: Partial<Task> = {}): Task {
    return {
      id,
      userId: 'user-1',
      title: 'C',
      type: TaskType.COUNTING,
      maxCount,
      action: 'Run',
      unit: 'mi',
      isCompleted: false,
      currentCount: 0,
      totalCompletions: 0,
      totalInstances: 1,
      createdAt: BOARD.startDate,
      updatedAt: BOARD.startDate,
      version: 1,
      isDeleted: false,
      ...over,
    };
  }

  function inc(id: string, taskId: string, delta: number, occurredAt: string): TaskEvent {
    return {
      id,
      userId: 'user-1',
      taskId,
      kind: 'increment',
      delta,
      occurredAt,
      createdAt: occurredAt,
      updatedAt: occurredAt,
      version: 1,
      isDeleted: false,
    };
  }

  it('shows the sealed-bounded windowed count for a plain counter — never the max/0 snapshot', () => {
    const task = counter('c1', 5, { currentCount: 99 }); // stale lifetime cache — must NOT leak
    const events = {
      c1: [inc('e1', 'c1', 2, '2026-07-01T10:00:00.000Z'), inc('e2', 'c1', 1, '2026-07-01T11:00:00.000Z')],
    };
    expect(resolveClosedBoardCounterDisplay(task, events, BOARD)).toEqual({ displayed: 3, isCompleted: false });
  });

  it('excludes a post-sealedAt increment (belongs to the next window)', () => {
    const task = counter('c1', 5);
    const events = {
      c1: [inc('e1', 'c1', 5, '2026-07-01T10:00:00.000Z'), inc('e2', 'c1', 5, '2026-07-03T00:00:00.000Z')],
    };
    expect(resolveClosedBoardCounterDisplay(task, events, BOARD)).toEqual({ displayed: 5, isCompleted: true });
  });

  it('resolves a window-stamped derived counter from the ROOT, never its own (absent) events', () => {
    const derived = counter('derived', 5, {
      sharedCounterId: 'root',
      startDate: BOARD.startDate,
      endDate: BOARD.endDate,
      createdInWizard: true,
      baseline: 0,
    });
    const events = { root: [inc('e1', 'root', 3, '2026-07-01T10:00:00.000Z')] };
    expect(resolveClosedBoardCounterDisplay(derived, events, BOARD)).toEqual({ displayed: 3, isCompleted: false });
  });

  it('a hub-linked row (no window stamp) shows the ROOT\'s sealed-bounded sum over the board window, never its latch (owner rule 2026-10-01)', () => {
    const hubLinked = counter('linked', 5, { sharedCounterId: 'root', currentCount: 7, isCompleted: true });
    const events = {
      root: [
        inc('e1', 'root', 3, '2026-07-01T10:00:00.000Z'), // in window
        inc('e2', 'root', 9, '2026-07-03T00:00:00.000Z'), // after the seal → dropped
      ],
    };
    expect(resolveClosedBoardCounterDisplay(hubLinked, events, BOARD)).toEqual({ displayed: 3, isCompleted: false });
  });

  it('agrees with the sealed snapshot bound: an event exactly at sealedAt counts (when sealedAt is the binding bound), one ms after does not', () => {
    // endDate LATER than sealedAt so sealedAt (not endDate) is the binding
    // upper bound — isolates the sealedAt-bound behavior, same pattern as
    // the shared sealReDerivationVectors.json fixture.
    const board = { ...BOARD, endDate: '2026-07-02T23:59:59.999Z' };
    const task = counter('c1', 1);
    const atSeal = { c1: [inc('e1', 'c1', 1, board.sealedAt)] };
    expect(resolveClosedBoardCounterDisplay(task, atSeal, board).isCompleted).toBe(true);

    const afterSeal = { c1: [inc('e1', 'c1', 1, '2026-07-02T00:00:01.001Z')] };
    expect(resolveClosedBoardCounterDisplay(task, afterSeal, board).displayed).toBe(0);
  });
});

describe('taskToSquareData — counter kinds (docs/COUNTER_KINDS.md D5)', () => {
  const counting = (over: Partial<Task>): Task => ({
    id: 't', userId: 'user-1', title: 'Run 26.2 mi', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 26.2,
    isCompleted: false, totalCompletions: 0, totalInstances: 0, createdAt: WINDOW_START, updatedAt: WINDOW_START,
    version: 1, isDeleted: false, ...over,
  });

  it('carries the row kind, and a linked row takes its root kind', () => {
    const root = counting({ id: 'root', countKind: 'continuous' });
    const linked = counting({ id: 'lk', sharedCounterId: 'root' });
    expect(taskToSquareData(root).countKind).toBe('continuous');
    expect(taskToSquareData(linked, undefined, { root, lk: linked }).countKind).toBe('continuous');
    expect(taskToSquareData(counting({ id: 'plain' })).countKind).toBe('discrete');
    expect(taskToSquareData(makeLifetimeCompleteTask('n')).countKind).toBeUndefined();
  });
});
