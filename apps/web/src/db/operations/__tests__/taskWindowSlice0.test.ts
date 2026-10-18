import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { db } from '../../internal';
import { decrementSharedCounter } from '../tasks.sharedCounter';
import { ROOT, USER, clearAll, rootTask } from './linkedCounterFixtures';

/**
 * TASK_WINDOW_REWORK slice 0 — the folded-in data-layer fixes that have no
 * better home: decrement never completes (iOS parity).
 */

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-10-01T00:00:00.000Z'));
});

afterEach(async () => {
  vi.useRealTimers();
  await clearAll();
});

describe('decrementSharedCounter never completes (slice 0, iOS parity)', () => {
  it('a root past its goal with the latch down stays incomplete after a decrement', async () => {
    // Goal set after the count ran past it: 7 of 5, latch false.
    await db.tasks.put(rootTask({ currentCount: 7, maxCount: 5, isCompleted: false }));
    await db.taskEvents.put({
      id: 'e7', userId: USER, taskId: ROOT, kind: 'increment', delta: 7,
      occurredAt: '2026-09-01T00:00:00.000Z', createdAt: '2026-09-01T00:00:00.000Z',
      updatedAt: '2026-09-01T00:00:00.000Z', version: 1, isDeleted: false,
    });
    await decrementSharedCounter(ROOT, 1);
    const root = (await db.tasks.get(ROOT))!;
    expect(root.currentCount).toBe(6);
    expect(root.isCompleted).toBe(false);
    expect(root.completedAt).toBeUndefined();
  });
});
