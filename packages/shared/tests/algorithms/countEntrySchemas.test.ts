import { TaskType } from '../../src/constants/enums';
import { AutoCreateCompoundChildTaskSchema, CreateTaskInputSchema } from '../../src/validation/schemas';

it('a duration counting task needs no unit; discrete still does', () => {
  const base = { title: 'Practice 10h', type: TaskType.COUNTING, action: 'Practice', maxCount: 600 };
  expect(CreateTaskInputSchema.safeParse({ ...base, countKind: 'duration' }).success).toBe(true);
  expect(CreateTaskInputSchema.safeParse({ ...base }).success).toBe(false);
  expect(AutoCreateCompoundChildTaskSchema.safeParse({ ...base, countKind: 'duration' }).success).toBe(true);
  expect(AutoCreateCompoundChildTaskSchema.safeParse({ ...base, countKind: 'discrete', maxCount: 2.5, unit: 'x' }).success).toBe(false);
});
