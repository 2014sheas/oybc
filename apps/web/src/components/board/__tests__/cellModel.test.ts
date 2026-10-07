import { describe, expect, it } from 'vitest';
import { TaskType, resolveFamilyCountKind, type Task } from '@oybc/shared';
import { cellCountFit, cellTypeOf, freeCellModel, taskCellLabel, toBoardCellModel } from '../cellModel';

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
    expect(counting.count).toEqual({ cur: 2, max: 5, kind: 'discrete' });
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

  it('labels an untitled Duration counter in hours', () => {
    const t = task({ title: '', type: TaskType.COUNTING, action: 'Code', maxCount: 30000, unit: '', countKind: 'duration' });
    expect(taskCellLabel(t)).toBe('Code 500h');
  });

  it('R19: a pending linked task renders its root kind', () => {
    const root = task({ id: 'root', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' });
    const pending = task({ id: 'p', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 6.2, sharedCounterId: 'root', baseline: 0 });
    const model = toBoardCellModel({ key: 'p', task: pending, done: false, currentCount: 3.1,
      countKind: resolveFamilyCountKind(pending, (id) => ({ root } as Record<string, Task>)[id]) });
    expect(model.count).toEqual({ cur: 3.1, max: 6.2, kind: 'continuous' });
  });
});

describe('cellCountFit (Review Focus 5)', () => {
  it.each([
    { cur: 12.75, max: 26.2, kind: 'continuous', size: 90, tier: 'full', text: '12.75/26.2' },
    { cur: 128.5, max: 1000, kind: 'continuous', size: 90, tier: 'full', text: '128.5/1000' },
    { cur: 6735, max: 30000, kind: 'duration', size: 90, tier: 'cur', text: '112h 15m' },
    { cur: 270, max: 600, kind: 'duration', size: 90, tier: 'full', text: '4h 30m/10h' },
    { cur: 6735, max: 30000, kind: 'duration', size: 58, tier: 'none', text: '' },
    { cur: 28.4, max: 26.2, kind: 'continuous', size: 90, tier: 'full', text: '28.4/26.2' },
    { cur: 3, max: 5, kind: 'discrete', size: 58, tier: 'full', text: '3/5' },
  ] as const)('$text @ $size', ({ cur, max, kind, size, tier, text }) => {
    expect(cellCountFit(cur, max, kind, size)).toEqual({ tier, text });
  });
});
