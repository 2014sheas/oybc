import { describe, expect, it } from 'vitest';
import { OperatorType, TaskType, type CompoundChild, type Task, type TaskEvent } from '@oybc/shared';
import { buildSquareWindowContext } from '../../../db/adapters';
import { taskToModel } from '../BoardWizardPreviewStep';

/**
 * Wizard-preview windowed completion (the "green squares from previous
 * windows" bug): the preview grid's `done`/count must resolve against the
 * PROSPECTIVE board's window, never the task's lifetime cache. Mirrors the
 * iOS pin in `WizardPreviewCompletionTests.swift`.
 */

const WINDOW_START = '2026-07-01T00:00:00.000Z';
const BEFORE_WINDOW = '2026-06-15T12:00:00.000Z';
const IN_WINDOW = '2026-07-10T12:00:00.000Z';

function makeTask(overrides: Partial<Task>): Task {
  return {
    id: 't1',
    userId: 'u1',
    title: 'Task',
    type: TaskType.NORMAL,
    isCompleted: false,
    currentCount: 0,
    totalCompletions: 0,
    createdAt: BEFORE_WINDOW,
    updatedAt: BEFORE_WINDOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  } as Task;
}

function makeEvent(taskId: string, kind: 'completion' | 'increment', occurredAt: string, delta?: number): TaskEvent {
  return {
    id: `ev-${taskId}-${occurredAt}`,
    userId: 'u1',
    taskId,
    kind,
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  } as TaskEvent;
}

function ctx(events: TaskEvent[]) {
  return buildSquareWindowContext(events, WINDOW_START);
}

describe('wizard preview — windowed completion', () => {
  it('a task completed in a PREVIOUS window previews grey despite its lifetime cache', () => {
    const task = makeTask({ isCompleted: true, totalCompletions: 1 });
    const model = taskToModel(task, { [task.id]: task }, {}, ctx([makeEvent(task.id, 'completion', BEFORE_WINDOW)]));
    expect(model.done).toBe(false);
  });

  it('a task completed INSIDE the new window previews green', () => {
    const task = makeTask({ isCompleted: true, totalCompletions: 1 });
    const model = taskToModel(task, { [task.id]: task }, {}, ctx([makeEvent(task.id, 'completion', IN_WINDOW)]));
    expect(model.done).toBe(true);
  });

  it('counting: count and done reflect only in-window increments', () => {
    const task = makeTask({ type: TaskType.COUNTING, maxCount: 5, currentCount: 5, isCompleted: true });
    const events = [
      makeEvent(task.id, 'increment', BEFORE_WINDOW, 5),
      makeEvent(task.id, 'increment', IN_WINDOW, 2),
    ];
    const model = taskToModel(task, { [task.id]: task }, {}, ctx(events));
    expect(model.done).toBe(false);
    expect(model.count).toEqual({ cur: 2, max: 5 });
  });

  it('derived (shared-counter-linked) counting keeps its lifetime carve-out', () => {
    const task = makeTask({
      type: TaskType.COUNTING,
      maxCount: 10,
      currentCount: 10,
      isCompleted: true,
      sharedCounterId: 'src-1',
      baseline: 0,
    });
    const model = taskToModel(task, { [task.id]: task }, {}, ctx([]));
    expect(model.done).toBe(true);
  });

  it('compound: evaluates windowed through its children, not the lifetime cache', () => {
    const child = makeTask({ id: 'child-1', isCompleted: true, totalCompletions: 1 });
    const compound = makeTask({
      id: 'comp-1',
      type: TaskType.COMPOUND,
      operator: OperatorType.AND,
      isCompleted: true,
    });
    const link: CompoundChild = {
      id: 'cc-1',
      compoundTaskId: compound.id,
      childTaskId: child.id,
      childIndex: 0,
      createdAt: BEFORE_WINDOW,
      updatedAt: BEFORE_WINDOW,
      version: 1,
      isDeleted: false,
    };
    const taskMap = { [compound.id]: compound, [child.id]: child };
    const children = { [compound.id]: [link] };

    const stale = taskToModel(compound, taskMap, children, ctx([makeEvent(child.id, 'completion', BEFORE_WINDOW)]));
    expect(stale.done).toBe(false);

    const fresh = taskToModel(compound, taskMap, children, ctx([makeEvent(child.id, 'completion', IN_WINDOW)]));
    expect(fresh.done).toBe(true);
  });
});
