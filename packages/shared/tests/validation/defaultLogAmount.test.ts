import { TaskSchema } from '../../src/validation/schemas';
import { TaskType } from '../../src/constants/enums';

const baseRow = {
  id: '123e4567-e89b-42d3-a456-426614174001',
  userId: 'u1',
  title: 'Push-ups (reps)',
  type: TaskType.COUNTING,
  action: 'Push-ups',
  unit: 'reps',
  isCompleted: false,
  totalCompletions: 0,
  totalInstances: 0,
  createdAt: '2026-07-15T00:00:00.000Z',
  updatedAt: '2026-07-15T00:00:00.000Z',
  version: 1,
  isDeleted: false,
};

describe('Task.defaultLogAmount (R2 — Counters UX refresh)', () => {
  it('accepts a positive integer', () => {
    const row = TaskSchema.safeParse({ ...baseRow, defaultLogAmount: 10 });
    expect(row.success).toBe(true);
    if (row.success) expect(row.data.defaultLogAmount).toBe(10);
  });

  it('accepts 1 (the smallest positive integer)', () => {
    expect(TaskSchema.safeParse({ ...baseRow, defaultLogAmount: 1 }).success).toBe(true);
  });

  it('is absent-ok (no defaultLogAmount at all)', () => {
    const row = TaskSchema.safeParse({ ...baseRow });
    expect(row.success).toBe(true);
    if (row.success) expect(row.data.defaultLogAmount).toBeUndefined();
  });

  it('rejects 0', () => {
    expect(TaskSchema.safeParse({ ...baseRow, defaultLogAmount: 0 }).success).toBe(false);
  });

  it('rejects a negative amount', () => {
    expect(TaskSchema.safeParse({ ...baseRow, defaultLogAmount: -5 }).success).toBe(false);
  });

  it('rejects a non-integer (float) amount', () => {
    expect(TaskSchema.safeParse({ ...baseRow, defaultLogAmount: 10.5 }).success).toBe(false);
  });
});
