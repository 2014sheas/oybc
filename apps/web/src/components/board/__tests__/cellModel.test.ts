import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { cellTypeOf, freeCellModel, taskCellLabel, toBoardCellModel } from '../cellModel';

function task(overrides: Partial<Task>): Task {
  return {
    id: 't1',
    userId: 'u1',
    title: 'Read',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('cellModel (Board Edit redesign slice 1 — one mapper for every surface)', () => {
  it('maps task types to cell types', () => {
    expect(cellTypeOf(TaskType.NORMAL)).toBe('normal');
    expect(cellTypeOf(TaskType.COUNTING)).toBe('counting');
    expect(cellTypeOf(TaskType.COMPOUND)).toBe('compound');
    expect(cellTypeOf(TaskType.ACHIEVEMENT)).toBe('normal');
  });

  it('labels an untitled counting task with the generated counter name', () => {
    const t = task({ title: '', type: TaskType.COUNTING, action: 'Run', maxCount: 20, unit: 'miles' });
    expect(taskCellLabel(t)).toMatch(/Run/);
    expect(taskCellLabel(t)).toMatch(/20/);
    expect(taskCellLabel(task({ title: '  ' }))).toBe('');
  });

  it('shapes count only for counting tasks and carries lock / dirty', () => {
    const counting = toBoardCellModel({
      key: 'bt1', task: task({ type: TaskType.COUNTING, maxCount: 5 }), done: false, currentCount: 2, locked: true,
    });
    expect(counting.type).toBe('counting');
    expect(counting.count).toEqual({ cur: 2, max: 5 });
    expect(counting.locked).toBe(true);
    expect(counting.dirty).toBeUndefined();

    const normal = toBoardCellModel({ key: 'bt2', task: task({}), done: true, currentCount: 9, dirty: true });
    expect(normal.count).toBeUndefined();
    expect(normal.done).toBe(true);
    expect(normal.dirty).toBe(true);
    expect(normal.locked).toBeUndefined();
    expect(normal.isFree).toBe(false);
  });

  it('builds the FREE center', () => {
    const free = freeCellModel('center', 'FREE', true);
    expect(free.isFree).toBe(true);
    expect(free.done).toBe(true);
    expect(free.locked).toBe(true);
  });
});
