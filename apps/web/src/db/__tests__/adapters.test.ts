import { describe, expect, it } from 'vitest';
import { TaskType, type Task, type TaskEvent } from '@oybc/shared';
import { buildSquareWindowContext, taskToSquareState } from '../adapters';

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

    const ctx = buildSquareWindowContext(events, WINDOW_START);

    expect(ctx.windowStart).toBe(WINDOW_START);
    expect(ctx.eventsByTaskId['task-a']).toHaveLength(2);
    expect(ctx.eventsByTaskId['task-b']).toBeUndefined();
  });

  it('returns an empty grouping for an empty event list', () => {
    const ctx = buildSquareWindowContext([], WINDOW_START);
    expect(ctx.eventsByTaskId).toEqual({});
  });
});

describe('mini-poster data path (RisoBoard + rearrange-preview regression)', () => {
  it('a lifetime-complete task with only a pre-window completion event resolves windowed-grey', () => {
    const task = makeLifetimeCompleteTask('task-a');
    const events = [makePriorCompletionEvent('task-a')];
    const windowContext = buildSquareWindowContext(events, WINDOW_START);

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
    const windowContext = buildSquareWindowContext(events, WINDOW_START);

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
