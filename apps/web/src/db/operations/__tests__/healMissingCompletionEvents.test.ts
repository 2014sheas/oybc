import { describe, it, expect, afterEach } from 'vitest';
import { db } from '../../internal';
import { healMissingCompletionEvents } from '../taskEventPull';
import { backfillTaskEventId, TaskType, type Task } from '@oybc/shared';

const NOW = '2026-07-16T10:00:00.000Z';

function normalTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'n1',
    userId: 'u1',
    title: 'Meditate',
    type: TaskType.NORMAL,
    isCompleted: false,
    completedAt: null,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  } as unknown as Task;
}

function countingTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'c1',
    userId: 'u1',
    title: 'Push-ups 100 reps',
    type: TaskType.COUNTING,
    action: 'Push-ups',
    unit: 'reps',
    sharedCounterId: null,
    maxCount: 100,
    currentCount: 0,
    isCompleted: false,
    completedAt: null,
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

describe('healMissingCompletionEvents', () => {
  it('mints + enqueues a completion event for a completed NORMAL task with no live event', async () => {
    await db.tasks.put(
      normalTask({ id: 'n1', isCompleted: true, completedAt: '2026-07-10T08:00:00.000Z' }),
    );

    const minted = await healMissingCompletionEvents('u1');
    expect(minted).toBe(1);

    const expectedId = backfillTaskEventId('n1', 'completion');
    const ev = await db.taskEvents.get(expectedId);
    expect(ev).toBeDefined();
    expect(ev?.kind).toBe('completion');
    expect(ev?.occurredAt).toBe('2026-07-10T08:00:00.000Z');
    expect(ev?.isDeleted).toBe(false);

    const queued = await db.syncQueue
      .filter((q) => q.entityType === 'taskEvents' && q.entityId === expectedId)
      .toArray();
    expect(queued.length).toBe(1);
  });

  it('mints an increment event for a plain COUNTING task with currentCount > 0', async () => {
    await db.tasks.put(countingTask({ id: 'c1', currentCount: 42 }));

    const minted = await healMissingCompletionEvents('u1');
    expect(minted).toBe(1);

    const ev = await db.taskEvents.get(backfillTaskEventId('c1', 'increment'));
    expect(ev?.kind).toBe('increment');
    expect(ev?.delta).toBe(42);
  });

  it('is idempotent — a second run mints nothing (deterministic id already present)', async () => {
    await db.tasks.put(
      normalTask({ id: 'n1', isCompleted: true, completedAt: '2026-07-10T08:00:00.000Z' }),
    );
    expect(await healMissingCompletionEvents('u1')).toBe(1);
    expect(await healMissingCompletionEvents('u1')).toBe(0);
    // exactly one event row, no duplication
    const all = await db.taskEvents.toArray();
    expect(all.length).toBe(1);
  });

  it('skips a task that already has a live event (events are authoritative)', async () => {
    await db.tasks.put(
      normalTask({ id: 'n1', isCompleted: true, completedAt: '2026-07-10T08:00:00.000Z' }),
    );
    await db.taskEvents.put({
      id: 'real-event',
      userId: 'u1',
      taskId: 'n1',
      kind: 'completion',
      occurredAt: '2026-07-09T00:00:00.000Z',
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    });

    expect(await healMissingCompletionEvents('u1')).toBe(0);
    // no backfill row minted
    const backfill = await db.taskEvents.get(backfillTaskEventId('n1', 'completion'));
    expect(backfill).toBeUndefined();
  });

  it('respects a winning tombstone (an explicit undo) — never resurrects it', async () => {
    await db.tasks.put(
      normalTask({ id: 'n1', isCompleted: true, completedAt: '2026-07-10T08:00:00.000Z' }),
    );
    // A deleted (undone) event at the DETERMINISTIC id, version-bumped by the undo.
    // isCompleted is stale-true, but the user explicitly undid it — heal must NOT
    // blind-overwrite the tombstone. LWW: existing v5 beats the mint's v1 → skip.
    const tombId = backfillTaskEventId('n1', 'completion');
    await db.taskEvents.put({
      id: tombId,
      userId: 'u1',
      taskId: 'n1',
      kind: 'completion',
      occurredAt: '2026-07-10T08:00:00.000Z',
      createdAt: NOW,
      updatedAt: NOW,
      version: 5,
      isDeleted: true,
      deletedAt: NOW,
    });

    const minted = await healMissingCompletionEvents('u1');
    expect(minted).toBe(0);
    // The tombstone survives untouched — undone state is not resurrected.
    const ev = await db.taskEvents.get(tombId);
    expect(ev?.isDeleted).toBe(true);
    expect(ev?.version).toBe(5);
  });

  it('leaves an incomplete task alone (isCompleted false, count 0 → no mint)', async () => {
    await db.tasks.put(normalTask({ id: 'n1', isCompleted: false }));
    await db.tasks.put(countingTask({ id: 'c1', currentCount: 0 }));
    expect(await healMissingCompletionEvents('u1')).toBe(0);
    expect((await db.taskEvents.toArray()).length).toBe(0);
  });

  it('skips carve-outs: derived counter, compound, achievement', async () => {
    await db.tasks.put(
      countingTask({ id: 'derived', sharedCounterId: 'src1', currentCount: 12 }),
    );
    await db.tasks.put(
      normalTask({ id: 'comp', type: TaskType.COMPOUND, isCompleted: true, completedAt: NOW }),
    );
    await db.tasks.put(
      normalTask({ id: 'ach', type: TaskType.ACHIEVEMENT, isCompleted: true, completedAt: NOW }),
    );
    expect(await healMissingCompletionEvents('u1')).toBe(0);
  });

  it('scopes to the given userId', async () => {
    await db.tasks.put(
      normalTask({ id: 'mine', userId: 'u1', isCompleted: true, completedAt: NOW }),
    );
    await db.tasks.put(
      normalTask({ id: 'theirs', userId: 'u2', isCompleted: true, completedAt: NOW }),
    );
    expect(await healMissingCompletionEvents('u1')).toBe(1);
    expect(await db.taskEvents.get(backfillTaskEventId('theirs', 'completion'))).toBeUndefined();
  });

  it('skips a soft-deleted task', async () => {
    await db.tasks.put(
      normalTask({ id: 'gone', isCompleted: true, completedAt: NOW, isDeleted: true }),
    );
    expect(await healMissingCompletionEvents('u1')).toBe(0);
  });
});
