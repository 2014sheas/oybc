import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { BoardStatus, Timeframe } from '@oybc/shared';
import { db } from '../../internal';
import { decrementSharedCounter } from '../tasks.sharedCounter';
import { healLinkedCounterWindows } from '../linkedCounterWindowHeal';
import { JUNE, ROOT, USER, boardRow, clearAll, hubLinked, placement, queued, rootTask } from './linkedCounterFixtures';

/**
 * TASK_WINDOW_REWORK slice 0 — the folded-in data-layer fixes that have no
 * better home: decrement never completes (iOS parity), drafts never feed
 * the linked-window heal, and an un-stamp resets the baseline.
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

describe('healLinkedCounterWindows ignores drafts (slice 0)', () => {
  it('a hub-linked row placed only on a DRAFT board is not stamped', async () => {
    await db.tasks.bulkPut([rootTask({ currentCount: 7 }), hubLinked('H')]);
    await db.boards.put(boardRow(JUNE, { status: BoardStatus.DRAFT, timeframe: Timeframe.MONTHLY }));
    await db.boardTasks.put(placement('bt-h', JUNE.id, 'H'));

    expect(await healLinkedCounterWindows(USER)).toEqual({ stamped: 0, copied: 0, unstamped: 0 });
    expect((await db.tasks.get('H'))!.startDate).toBeUndefined();
    expect(await queued('tasks')).toEqual([]);
  });
});
