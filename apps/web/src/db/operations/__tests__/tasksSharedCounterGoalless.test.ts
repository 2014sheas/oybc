import { describe, it, expect, afterEach } from 'vitest';
import { db } from '../../internal';
import { incrementSharedCounter, decrementSharedCounter } from '../tasks.sharedCounter';
import { insertIncrementEventRaw } from '../taskEvents';
import { SEED_EVENT_OCCURRED_AT, TaskType, type Task } from '@oybc/shared';

const NOW = '2026-07-16T10:00:00.000Z';
function goallessSource(id = 'src1'): Task {
  return {
    id, userId: 'u1', title: 'Push-ups (reps)', type: TaskType.COUNTING,
    action: 'Push-ups', unit: 'reps', isCounter: true,
    currentCount: 0, isCompleted: false, totalCompletions: 0, totalInstances: 0,
    createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false,
  } as unknown as Task;
}
afterEach(async () => {
  await Promise.all([db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(),
    db.boardTasks.clear(), db.compoundChildren.clear(), db.syncQueue.clear()]);
});

describe('goal-less counter engine (P5)', () => {
  it('increments a goal-less source without throwing; never auto-completes', async () => {
    await db.tasks.add(goallessSource());
    await incrementSharedCounter('src1', 5);
    const t = await db.tasks.get('src1');
    expect(t!.currentCount).toBe(5);
    expect(t!.isCompleted).toBe(false);
  });
  it('decrements a goal-less source without throwing', async () => {
    await db.tasks.add({ ...goallessSource(), currentCount: 3 });
    const r = await decrementSharedCounter('src1', 2);
    expect(r.effectiveDelta).toBe(2);
    expect((await db.tasks.get('src1'))!.currentCount).toBe(1);
  });
  it('goaled source latch still fires (regression)', async () => {
    await db.tasks.add({ ...goallessSource('src2'), isCounter: undefined, maxCount: 5 });
    await incrementSharedCounter('src2', 5);
    expect((await db.tasks.get('src2'))!.isCompleted).toBe(true);
  });
  it('insertIncrementEventRaw honors an occurredAt override (seed sentinel)', async () => {
    await db.tasks.add(goallessSource('src3'));
    await db.transaction('rw', [db.tasks, db.taskEvents, db.syncQueue], async () => {
      await insertIncrementEventRaw('src3', 500, undefined, NOW, SEED_EVENT_OCCURRED_AT);
    });
    const ev = await db.taskEvents.where('taskId').equals('src3').first();
    expect(ev!.occurredAt).toBe(SEED_EVENT_OCCURRED_AT);
    expect(ev!.createdAt).toBe(NOW);
  });
});
