import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { displayedCountFor } from '../../../pages/tasks/taskCountDisplay';
import { incrementSharedCounter, setCounterDefaultLogAmount } from '../tasks.sharedCounter';

const NOW = '2026-07-20T10:00:00.000Z';

afterEach(async () => {
  await db.tasks.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedCounter(over: Partial<Task>): Promise<Task> {
  const task = {
    id: crypto.randomUUID(),
    userId: 'u1',
    title: 'Run',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'miles',
    maxCount: 10,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
  await db.tasks.add(task);
  return task;
}

describe('counter kinds — web write-path guards', () => {
  it('incrementSharedCounter accepts a 2dp amount and writes a 2dp delta', async () => {
    const root = await seedCounter({ countKind: 'continuous', maxCount: 26.2 });
    await incrementSharedCounter(root.id, 3.1);
    const events = await db.taskEvents.where('taskId').equals(root.id).toArray();
    expect(events.map((e) => e.delta)).toEqual([3.1]);
  });

  it('incrementSharedCounter rejects a 3dp amount', async () => {
    const root = await seedCounter({ countKind: 'continuous', maxCount: 26.2 });
    await expect(incrementSharedCounter(root.id, 3.125)).rejects.toThrow(/2dp/);
  });

  it('keeps the lifetime cache drift-free (0.1 + 0.2 = 0.3)', async () => {
    const root = await seedCounter({ countKind: 'continuous', maxCount: 0.3 });
    await incrementSharedCounter(root.id, 0.1);
    await incrementSharedCounter(root.id, 0.2);
    expect((await db.tasks.get(root.id))!.currentCount).toBe(0.3);
  });

  it('setCounterDefaultLogAmount accepts 2dp', async () => {
    const root = await seedCounter({ countKind: 'continuous', maxCount: 26.2 });
    await setCounterDefaultLogAmount(root.id, 3.1);
    expect((await db.tasks.get(root.id))!.defaultLogAmount).toBe(3.1);
  });

  it('propagation keeps a continuous linked row\'s fraction (0.5 is not rounded to 1)', async () => {
    const root = await seedCounter({ countKind: 'continuous', maxCount: 10 });
    const linked = await seedCounter({
      countKind: 'continuous',
      sharedCounterId: root.id,
      baseline: 0,
      maxCount: 1,
      currentCount: undefined,
    });
    await incrementSharedCounter(root.id, 0.5);
    const after = (await db.tasks.get(linked.id))!;
    expect(after.currentCount).toBe(0.5);
    expect(after.isCompleted).toBe(false);
    expect(displayedCountFor(after)).toBe(0.5);
  });
});
