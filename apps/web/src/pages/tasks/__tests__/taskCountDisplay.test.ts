import { describe, expect, it } from 'vitest';
import { TaskType, type Task, type TaskEvent } from '@oybc/shared';
import { displayedCountFor } from '../taskCountDisplay';
import { isInProgress } from '../useTasksFilters';
import type { TaskLibrary } from '../../createPage/useTaskLibrary';

/**
 * Slice 2c — context-less library readers read the workspace event log
 * (`contextlessCounterState`), never `baseline`, `currentCount` or the
 * `isCompleted` latch. A linked row measures its ROOT's lifetime increments.
 */

const NOW = '2026-09-18T10:00:00.000Z';

function task(over: Partial<Task> = {}): Task {
  return {
    id: 't1',
    userId: 'u1',
    title: 'Run 5 km',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'km',
    maxCount: 5,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function inc(taskId: string, delta: number, id = `${taskId}-${delta}-${Math.random()}`): TaskEvent {
  return {
    id,
    userId: 'u1',
    taskId,
    kind: 'increment',
    delta,
    occurredAt: NOW,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  } as TaskEvent;
}

const LINKED = task({ sharedCounterId: 'root-1', baseline: 10, maxCount: 5, currentCount: 12 });
const ROOT = task({ id: 'root-1', currentCount: 99, maxCount: 20 });

const LIBRARY = { taskMap: {}, compoundChildrenByCompound: {} } as unknown as TaskLibrary;

describe('displayedCountFor', () => {
  it('a linked row reads its ROOT’s lifetime increments, ignoring baseline / mirror', () => {
    expect(displayedCountFor(LINKED, { 'root-1': [inc('root-1', 3), inc('root-1', 4)] })).toBe(7);
  });

  it('a root / standalone counter reads its own events, ignoring currentCount', () => {
    expect(displayedCountFor(ROOT, { 'root-1': [inc('root-1', 2)] })).toBe(2);
  });

  it('is 0 with no events and never clamps overshoot', () => {
    expect(displayedCountFor(LINKED, null)).toBe(0);
    expect(displayedCountFor(LINKED, { 'root-1': [inc('root-1', 9)] })).toBe(9);
  });
});

describe('isInProgress (status filter)', () => {
  it('a linked member with root increments below goal is in progress', () => {
    expect(isInProgress(LINKED, LIBRARY, { 'root-1': [inc('root-1', 2)] })).toBe(true);
  });

  it('a counter with no events is not in progress, whatever its stale mirror says', () => {
    expect(isInProgress(LINKED, LIBRARY, {})).toBe(false);
  });

  it('a counter at its goal is done, not in progress', () => {
    expect(isInProgress(LINKED, LIBRARY, { 'root-1': [inc('root-1', 5)] })).toBe(false);
  });
});

describe('isInProgress — compound with a counting child (C7)', () => {
  const COMPOUND = task({ id: 'cmp', type: TaskType.COMPOUND, maxCount: undefined, action: undefined, unit: undefined } as Partial<Task>);
  const library = (child: Task) =>
    ({
      taskMap: { [child.id]: child, cmp: COMPOUND },
      compoundChildrenByCompound: { cmp: [{ compoundTaskId: 'cmp', childTaskId: child.id, childIndex: 0, isDeleted: false }] },
    }) as unknown as TaskLibrary;

  it('a linked counting child whose ROOT reached the goal counts as completed even with a stale latch', () => {
    const child = task({ id: 'kid', sharedCounterId: 'root-1', maxCount: 5, isCompleted: false });
    expect(isInProgress(COMPOUND, library(child), { 'root-1': [inc('root-1', 5)] })).toBe(true);
  });

  it('a counting child whose cache latch says completed but whose events say otherwise does not count', () => {
    const child = task({ id: 'kid', sharedCounterId: 'root-1', maxCount: 5, isCompleted: true });
    expect(isInProgress(COMPOUND, library(child), { 'root-1': [inc('root-1', 2)] })).toBe(false);
  });

  it('a non-counting child still reads the isCompleted cache', () => {
    const done = task({ id: 'kid', type: TaskType.NORMAL, isCompleted: true });
    expect(isInProgress(COMPOUND, library(done), {})).toBe(true);
    expect(isInProgress(COMPOUND, library({ ...done, isCompleted: false }), {})).toBe(false);
  });
});
