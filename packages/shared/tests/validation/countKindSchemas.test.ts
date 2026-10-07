import { TaskSchema, TaskEventSchema, CreateTaskInputSchema, UpdateTaskInputSchema } from '../../src/validation/schemas';
import { BoardSourceMemberRuleSchema } from '../../src/validation/boardSource';
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

function validIncrement(overrides: Record<string, unknown> = {}) {
  return {
    id: '00000000-0000-0000-0000-0000000000e2',
    userId: 'user-1',
    taskId: '10000000-0000-0000-0000-000000000001',
    kind: 'increment',
    delta: 3,
    occurredAt: '2026-07-05T12:00:00.000Z',
    createdAt: '2026-07-05T12:00:00.000Z',
    updatedAt: '2026-07-05T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

const baseCountingTask = () => ({ ...baseRow });
const baseIncrement = () => validIncrement();

describe('counter kinds — schemas', () => {
  it('accepts a continuous task with a fractional goal and count', () => {
    const r = TaskSchema.safeParse({ ...baseCountingTask(), countKind: 'continuous', maxCount: 26.2, currentCount: 3.1, defaultLogAmount: 3.1 });
    expect(r.success).toBe(true);
  });
  it('accepts a pre-feature task with no countKind', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), maxCount: 26 }).success).toBe(true);
  });
  it('rejects an unknown kind', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), countKind: 'weight' }).success).toBe(false);
  });
  it('rejects three decimal places', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), countKind: 'continuous', maxCount: 26.125 }).success).toBe(false);
  });
  it('rejects a fractional goal on a whole kind', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), maxCount: 26.2 }).success).toBe(false);
    expect(TaskSchema.safeParse({ ...baseCountingTask(), countKind: 'duration', maxCount: 90.5 }).success).toBe(false);
  });
  it('allows a fractional currentCount cache on a discrete task (switched history)', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), maxCount: 26, currentCount: 1.2 }).success).toBe(true);
  });
  it('accepts a fractional increment delta and rejects 3dp / zero', () => {
    expect(TaskEventSchema.safeParse({ ...baseIncrement(), delta: 3.1 }).success).toBe(true);
    expect(TaskEventSchema.safeParse({ ...baseIncrement(), delta: -0.25 }).success).toBe(true);
    expect(TaskEventSchema.safeParse({ ...baseIncrement(), delta: 3.125 }).success).toBe(false);
    expect(TaskEventSchema.safeParse({ ...baseIncrement(), delta: 0 }).success).toBe(false);
  });
  it('create input carries countKind', () => {
    const r = CreateTaskInputSchema.safeParse({ title: 'Run 26.2 miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles', maxCount: 26.2, countKind: 'continuous' });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.countKind).toBe('continuous');
  });
  it('create input rejects a fractional goal without a continuous kind', () => {
    const r = CreateTaskInputSchema.safeParse({ title: 'Run', type: TaskType.COUNTING, action: 'Run', unit: 'miles', maxCount: 26.2 });
    expect(r.success).toBe(false);
  });
  it('update input carries countKind', () => {
    const r = UpdateTaskInputSchema.safeParse({ countKind: 'continuous' });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.countKind).toBe('continuous');
  });
  it('member-rule target accepts 2dp, rejects zero', () => {
    expect(BoardSourceMemberRuleSchema.safeParse({ target: 6.1 }).success).toBe(true);
    expect(BoardSourceMemberRuleSchema.safeParse({ target: 0 }).success).toBe(false);
  });
});
