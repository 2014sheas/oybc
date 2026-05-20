import { isTaskExpired } from '../../src/algorithms/taskExpiry';
import { TaskType, Timeframe } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: '00000000-0000-0000-0000-000000000001',
    userId: 'u1',
    title: 'sample',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: '2026-05-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('isTaskExpired', () => {
  const NOW = new Date('2026-05-18T12:00:00.000Z');

  it('returns false for indefinite tasks (no endDate)', () => {
    expect(isTaskExpired(makeTask(), NOW)).toBe(false);
  });

  it('returns true when endDate is in the past', () => {
    expect(
      isTaskExpired(
        makeTask({
          timeframe: Timeframe.WEEKLY,
          startDate: '2026-05-04T00:00:00.000Z',
          endDate: '2026-05-10T23:59:59.999Z',
        }),
        NOW,
      ),
    ).toBe(true);
  });

  it('returns false when endDate is in the future', () => {
    expect(
      isTaskExpired(
        makeTask({
          timeframe: Timeframe.WEEKLY,
          startDate: '2026-05-18T00:00:00.000Z',
          endDate: '2026-05-25T23:59:59.999Z',
        }),
        NOW,
      ),
    ).toBe(false);
  });

  it('returns false when now exactly equals endDate (boundary inclusive)', () => {
    const endIso = NOW.toISOString();
    expect(
      isTaskExpired(
        makeTask({ endDate: endIso }),
        NOW,
      ),
    ).toBe(false);
  });

  it('returns false when endDate is unparseable (defensive)', () => {
    expect(
      isTaskExpired(makeTask({ endDate: 'not-a-date' }), NOW),
    ).toBe(false);
  });
});
