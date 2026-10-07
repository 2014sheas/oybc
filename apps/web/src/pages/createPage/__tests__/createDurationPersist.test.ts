import 'fake-indexeddb/auto';
import { describe, expect, it } from 'vitest';
import { TaskSchema, TaskType, generateCounterTaskTitle } from '@oybc/shared';
import { createTask } from '../../../db/operations/tasks.crud';

/**
 * The first surface that CREATES a Duration task: the write path must accept a
 * counting task with an empty unit, and the stored row must pass the same
 * schema the sync pull validates against.
 */
describe('createTask — Duration counting task', () => {
  it('persists with an empty unit, stores minutes, and passes TaskSchema', async () => {
    const title = generateCounterTaskTitle('Practice', 630, '', undefined, 'duration');
    const task = await createTask('user-1', {
      title,
      type: TaskType.COUNTING,
      action: 'Practice',
      unit: '',
      maxCount: 630,
      countKind: 'duration',
    });
    expect(task.title).toBe('Practice 10h 30m');
    expect(task.countKind).toBe('duration');
    expect(task.maxCount).toBe(630);
    expect(task.unit).toBe('');
    expect(TaskSchema.safeParse(task).success).toBe(true);
  });
});
