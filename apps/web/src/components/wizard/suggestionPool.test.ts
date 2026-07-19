import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import { mergeSuggestionPool } from './suggestionPool';

const NOW = '2026-07-18T10:00:00.000Z';

function task(overrides: Partial<Task> = {}): Task {
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
    ...overrides,
  } as unknown as Task;
}

function pendingPayload(t: Task): PendingTaskPayload {
  return { task: t, childTasks: [], childLinks: [] };
}

describe('mergeSuggestionPool — R1 counters refresh review fix (web wizard pending-counter matching)', () => {
  it('returns the persisted pool unchanged when there are no pending tasks', () => {
    const persisted = [task({ id: 'p1' })];
    expect(mergeSuggestionPool(persisted, undefined)).toEqual(persisted);
    expect(mergeSuggestionPool(persisted, new Map())).toEqual(persisted);
  });

  it('appends a pending task not already present in the persisted pool', () => {
    const persisted = [task({ id: 'p1' })];
    const pending = task({ id: 'pending1', title: 'Push-ups' });
    const pendingTasks = new Map([[pending.id, pendingPayload(pending)]]);

    const result = mergeSuggestionPool(persisted, pendingTasks);

    expect(result).toHaveLength(2);
    expect(result.map((t) => t.id)).toEqual(['p1', 'pending1']);
  });

  it('makes a same-session pending counter matchable — the exact bug this fixes: creating counting task A (pending) then a same-pair task B must see A', () => {
    const pendingA = task({ id: 'a', action: 'Run', unit: 'km' });
    const pendingTasks = new Map([[pendingA.id, pendingPayload(pendingA)]]);

    const result = mergeSuggestionPool([], pendingTasks);

    expect(result).toContainEqual(pendingA);
  });

  it('does not duplicate a task that is already persisted (persisted copy wins on id collision)', () => {
    const persistedCopy = task({ id: 'dup', title: 'Persisted title' });
    const pendingCopy = task({ id: 'dup', title: 'Pending title (stale)' });
    const pendingTasks = new Map([[pendingCopy.id, pendingPayload(pendingCopy)]]);

    const result = mergeSuggestionPool([persistedCopy], pendingTasks);

    expect(result).toHaveLength(1);
    expect(result[0].title).toBe('Persisted title');
  });

  it('merges multiple pending tasks, preserving persisted-first ordering', () => {
    const persisted = [task({ id: 'p1' }), task({ id: 'p2' })];
    const pendingTasks = new Map([
      ['pending1', pendingPayload(task({ id: 'pending1' }))],
      ['pending2', pendingPayload(task({ id: 'pending2' }))],
    ]);

    const result = mergeSuggestionPool(persisted, pendingTasks);

    expect(result.map((t) => t.id)).toEqual(['p1', 'p2', 'pending1', 'pending2']);
  });
});
