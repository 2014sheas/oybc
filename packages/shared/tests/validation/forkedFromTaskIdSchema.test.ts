import { TaskSchema } from '../../src/validation/schemas';
import { TaskType } from '../../src/constants/enums';

/**
 * Board-scoped task edits PR 1 (docs/BOARD_SCOPED_TASK_EDITS.md §3):
 * `Task.forkedFromTaskId` is a plain optional, nullable string that must
 * round-trip through the sync boundary (z.object strips undeclared keys).
 */
const baseRow = {
  id: '123e4567-e89b-42d3-a456-426614174001',
  userId: 'u1',
  title: 'Read',
  type: TaskType.NORMAL,
  isCompleted: false,
  totalCompletions: 0,
  totalInstances: 0,
  createdAt: '2026-07-15T00:00:00.000Z',
  updatedAt: '2026-07-15T00:00:00.000Z',
  version: 1,
  isDeleted: false,
};

describe('Task.forkedFromTaskId — schema', () => {
  it('keeps a set forkedFromTaskId through parse (not stripped)', () => {
    const r = TaskSchema.safeParse({ ...baseRow, forkedFromTaskId: '123e4567-e89b-42d3-a456-426614174000' });
    expect(r.success).toBe(true);
    expect(r.success && r.data.forkedFromTaskId).toBe('123e4567-e89b-42d3-a456-426614174000');
  });

  it('accepts an explicit null', () => {
    const r = TaskSchema.safeParse({ ...baseRow, forkedFromTaskId: null });
    expect(r.success).toBe(true);
    expect(r.success && r.data.forkedFromTaskId).toBeNull();
  });

  it('accepts a pre-feature payload with the field absent', () => {
    const r = TaskSchema.safeParse(baseRow);
    expect(r.success).toBe(true);
    expect(r.success && 'forkedFromTaskId' in r.data).toBe(false);
  });

  it('rejects a non-string value', () => {
    expect(TaskSchema.safeParse({ ...baseRow, forkedFromTaskId: 42 }).success).toBe(false);
  });
});
