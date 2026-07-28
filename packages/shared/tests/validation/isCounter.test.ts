import { CreateTaskInputSchema, TaskSchema } from '../../src/validation/schemas';
import { TaskType } from '../../src/constants/enums';

const base = { title: 'Push-ups (reps)', type: TaskType.COUNTING, action: 'Push-ups', unit: 'reps' };

describe('Task.isCounter (P5 hub-born counters)', () => {
  it('accepts a goal-less counting create when isCounter is true', () => {
    expect(CreateTaskInputSchema.safeParse({ ...base, isCounter: true }).success).toBe(true);
  });
  it('still rejects a goal-less counting create without the flag', () => {
    expect(CreateTaskInputSchema.safeParse({ ...base }).success).toBe(false);
  });
  it('accepts isCounter WITH a maxCount (promoted task keeps its goal)', () => {
    expect(CreateTaskInputSchema.safeParse({ ...base, isCounter: true, maxCount: 50 }).success).toBe(true);
  });
  it('rejects isCounter on a non-counting type', () => {
    expect(
      CreateTaskInputSchema.safeParse({ title: 'Call Mom', type: TaskType.NORMAL, isCounter: true }).success,
    ).toBe(false);
  });
  it('rejects isCounter on a derived (linked) counting task', () => {
    expect(
      CreateTaskInputSchema.safeParse({
        ...base, maxCount: 50, isCounter: true,
        sharedCounterId: '123e4567-e89b-42d3-a456-426614174000', baseline: 0,
      }).success,
    ).toBe(false);
  });
  it('TaskSchema round-trips isCounter on a row', () => {
    const row = TaskSchema.safeParse({
      id: '123e4567-e89b-42d3-a456-426614174001', userId: 'u1',
      title: 'Push-ups (reps)', type: TaskType.COUNTING, action: 'Push-ups', unit: 'reps',
      isCounter: true, isCompleted: false, totalCompletions: 0, totalInstances: 0,
      createdAt: '2026-07-15T00:00:00.000Z', updatedAt: '2026-07-15T00:00:00.000Z',
      version: 1, isDeleted: false,
    });
    expect(row.success).toBe(true);
    if (row.success) expect(row.data.isCounter).toBe(true);
  });
});
