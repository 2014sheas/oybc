import { describe, it, expect, afterEach } from 'vitest';
import { db } from '../../internal';
import {
  incrementSharedCounter,
  decrementSharedCounter,
  undoLastCounterLog,
  setCounterDefaultLogAmount,
} from '../tasks.sharedCounter';
import { SEED_EVENT_OCCURRED_AT, TaskType, BoardStatus, type Task } from '@oybc/shared';

const NOW = '2026-07-20T10:00:00.000Z';

function source(overrides: Partial<Task> = {}): Task {
  return {
    id: 'src1',
    userId: 'u1',
    title: 'Push-ups reps',
    type: TaskType.COUNTING,
    action: 'Push-ups',
    unit: 'reps',
    isCounter: true,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  } as unknown as Task;
}

function linkedMember(overrides: Partial<Task> = {}): Task {
  return {
    id: 'member1',
    userId: 'u1',
    title: 'Do 50 push-ups',
    type: TaskType.COUNTING,
    action: 'Do',
    unit: 'push-ups',
    sharedCounterId: 'src1',
    baseline: 0,
    maxCount: 50,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  } as unknown as Task;
}

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(),
    db.taskEvents.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('undoLastCounterLog (R2)', () => {
  it('tombstones the last increment event and corrects currentCount', async () => {
    await db.tasks.add(source());
    await incrementSharedCounter('src1', 5);
    await incrementSharedCounter('src1', 10);

    const result = await undoLastCounterLog('src1');
    expect(result.undoneAmount).toBe(10);

    const t = await db.tasks.get('src1');
    expect(t!.currentCount).toBe(5);

    const events = await db.taskEvents.where('taskId').equals('src1').toArray();
    const live = events.filter((e) => !e.isDeleted);
    expect(live).toHaveLength(1);
    expect(live[0].delta).toBe(5);
    const tombstoned = events.find((e) => e.isDeleted);
    expect(tombstoned).toBeDefined();
    expect(tombstoned!.delta).toBe(10);
  });

  it('reverses the last decrement (adds the amount back)', async () => {
    await db.tasks.add(source({ currentCount: 20 }));
    // Seed an initial log so currentCount already reflects 20 before decrementing.
    await decrementSharedCounter('src1', 7);
    expect((await db.tasks.get('src1'))!.currentCount).toBe(13);

    const result = await undoLastCounterLog('src1');
    expect(result.undoneAmount).toBe(7);
    expect((await db.tasks.get('src1'))!.currentCount).toBe(20);
  });

  it('propagates the correction to linked tasks', async () => {
    await db.tasks.add(source());
    await db.tasks.add(linkedMember());
    await incrementSharedCounter('src1', 30);
    expect((await db.tasks.get('member1'))!.currentCount).toBe(30);

    await undoLastCounterLog('src1');
    expect((await db.tasks.get('src1'))!.currentCount).toBe(0);
    expect((await db.tasks.get('member1'))!.currentCount).toBe(0);
  });

  it('collects affected ACTIVE boards', async () => {
    await db.tasks.add(source());
    await db.boards.add({
      id: 'board1',
      userId: 'u1',
      name: 'Daily Grind',
      status: BoardStatus.ACTIVE,
      boardSize: 3,
      isDeleted: false,
      totalTasks: 1,
      completedTasks: 0,
      linesCompleted: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
    } as never);
    await db.boardTasks.add({
      id: 'bt1',
      boardId: 'board1',
      taskId: 'src1',
      position: 0,
      isCenter: false,
      isDeleted: false,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
    } as never);

    await incrementSharedCounter('src1', 4);
    const result = await undoLastCounterLog('src1');
    expect(result.affectedBoards).toEqual([{ boardId: 'board1', boardName: 'Daily Grind' }]);
  });

  it('excludes the seed sentinel from the undo candidate', async () => {
    // A hub-born counter's seed event carries SEED_EVENT_OCCURRED_AT and
    // must never be the thing "Undo" reverses.
    await db.tasks.add(source({ currentCount: 500 }));
    await db.transaction('rw', [db.tasks, db.taskEvents, db.syncQueue], async () => {
      const { insertIncrementEventRaw } = await import('../taskEvents');
      await insertIncrementEventRaw('src1', 500, undefined, NOW, SEED_EVENT_OCCURRED_AT);
    });

    const result = await undoLastCounterLog('src1');
    expect(result.undoneAmount).toBe(0);
    expect((await db.tasks.get('src1'))!.currentCount).toBe(500);
  });

  it('is a no-op when there is no undoable entry', async () => {
    await db.tasks.add(source());
    const result = await undoLastCounterLog('src1');
    expect(result).toEqual({ affectedBoards: [], undoneAmount: 0 });
  });

  it('is a no-op when the source is missing or deleted', async () => {
    await expect(undoLastCounterLog('does-not-exist')).resolves.toEqual({
      affectedBoards: [],
      undoneAmount: 0,
    });
    await db.tasks.add(source({ isDeleted: true }));
    await expect(undoLastCounterLog('src1')).resolves.toEqual({
      affectedBoards: [],
      undoneAmount: 0,
    });
  });

  it('rejects a linked (derived) task id', async () => {
    await db.tasks.add(linkedMember());
    await expect(undoLastCounterLog('member1')).rejects.toThrow();
  });

  it('preserves the one-way completion latch (does not un-complete)', async () => {
    await db.tasks.add(source({ maxCount: 10 }));
    await incrementSharedCounter('src1', 10); // completes at exactly 10
    expect((await db.tasks.get('src1'))!.isCompleted).toBe(true);

    await undoLastCounterLog('src1');
    // currentCount drops back to 0, but the latch keeps isCompleted true.
    const t = await db.tasks.get('src1');
    expect(t!.currentCount).toBe(0);
    expect(t!.isCompleted).toBe(true);
  });
});

describe('setCounterDefaultLogAmount (R2)', () => {
  it('persists a new default amount with a version bump + sync entry', async () => {
    await db.tasks.add(source());
    await setCounterDefaultLogAmount('src1', 10);
    const t = await db.tasks.get('src1');
    expect(t!.defaultLogAmount).toBe(10);
    expect(t!.version).toBe(2);

    const queued = await db.syncQueue.filter((q) => q.entityId === 'src1').toArray();
    expect(queued.length).toBeGreaterThan(0);
  });

  it('is a no-op (no version bump) when the amount already matches', async () => {
    await db.tasks.add(source({ defaultLogAmount: 10 }));
    await setCounterDefaultLogAmount('src1', 10);
    const t = await db.tasks.get('src1');
    expect(t!.version).toBe(1);
  });

  it('rejects zero, negative, or fractional amounts', async () => {
    await db.tasks.add(source());
    await expect(setCounterDefaultLogAmount('src1', 0)).rejects.toThrow();
    await expect(setCounterDefaultLogAmount('src1', -5)).rejects.toThrow();
    await expect(setCounterDefaultLogAmount('src1', 1.5)).rejects.toThrow();
  });

  it('rejects a linked (derived) task id', async () => {
    await db.tasks.add(linkedMember());
    await expect(setCounterDefaultLogAmount('member1', 10)).rejects.toThrow();
  });

  it('is a no-op when the source is missing or deleted', async () => {
    await expect(setCounterDefaultLogAmount('does-not-exist', 5)).resolves.toBeUndefined();
    await db.tasks.add(source({ isDeleted: true }));
    await expect(setCounterDefaultLogAmount('src1', 5)).resolves.toBeUndefined();
  });
});
