import { describe, it, expect, afterEach } from 'vitest';
import { db } from '../../internal';
import {
  createCounterTask,
  promoteTaskToCounter,
  deleteCounterWithUnlink,
  computeTaskDeletionImpact,
  createCompound,
} from '../tasks';
import { createCompoundChild } from '../compoundChildren';
import { SEED_EVENT_OCCURRED_AT, TaskType, OperatorType, type Task } from '@oybc/shared';

const NOW = '2026-07-16T10:00:00.000Z';

function counterMember(overrides: Partial<Task> = {}): Task {
  return {
    id: 'member1',
    userId: 'u1',
    title: 'Push-ups goal',
    type: TaskType.COUNTING,
    action: 'Push-ups',
    unit: 'reps',
    sharedCounterId: 'src1',
    baseline: 10,
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

function standaloneCountingTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'standalone1',
    userId: 'u1',
    title: 'Push-ups 100 reps',
    type: TaskType.COUNTING,
    action: 'Push-ups',
    unit: 'reps',
    maxCount: 100,
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

describe('createCounterTask (P5)', () => {
  it('writes task + seed event atomically', async () => {
    const t = await createCounterTask('u1', {
      action: 'Push-ups',
      unit: 'reps',
      startingCount: 500,
    });
    expect(t.isCounter).toBe(true);
    expect(t.maxCount).toBeUndefined();
    // R1: goal-less title is now the pair-derived counter name
    // (formatCounterName) — action "Push-ups" isn't the elided "Do" verb,
    // so it renders "{Verb} {noun}", not the retired "{action} ({unit})".
    expect(t.title).toBe('Push-ups reps');
    expect(t.currentCount).toBe(500);
    expect(t.type).toBe(TaskType.COUNTING);

    const persisted = await db.tasks.get(t.id);
    expect(persisted).toBeDefined();
    expect(persisted!.currentCount).toBe(500);

    const events = await db.taskEvents.where('taskId').equals(t.id).toArray();
    expect(events).toHaveLength(1);
    expect(events[0].delta).toBe(500);
    expect(events[0].occurredAt).toBe(SEED_EVENT_OCCURRED_AT);
    expect(events[0].kind).toBe('increment');

    const queued = await db.syncQueue.filter((q) => q.entityId === t.id).toArray();
    expect(queued.length).toBeGreaterThan(0);
  });

  it('without startingCount writes no seed event and count 0', async () => {
    const t = await createCounterTask('u1', { action: 'Read', unit: 'pages' });
    expect(t.currentCount).toBe(0);
    expect(t.title).toBe('Read pages');
    const events = await db.taskEvents.where('taskId').equals(t.id).toArray();
    expect(events).toHaveLength(0);
  });

  it('rejects blank action/unit', async () => {
    await expect(createCounterTask('u1', { action: '  ', unit: 'reps' })).rejects.toThrow();
    await expect(createCounterTask('u1', { action: 'Push-ups', unit: '' })).rejects.toThrow();
  });

  it('rejects a negative or non-integer startingCount', async () => {
    await expect(
      createCounterTask('u1', { action: 'Push-ups', unit: 'reps', startingCount: -1 }),
    ).rejects.toThrow();
    await expect(
      createCounterTask('u1', { action: 'Push-ups', unit: 'reps', startingCount: 1.5 }),
    ).rejects.toThrow();
  });
});

describe('promoteTaskToCounter (P5)', () => {
  it('flags a standalone counting task as a counter', async () => {
    await db.tasks.add(standaloneCountingTask());
    const updated = await promoteTaskToCounter('standalone1');
    expect(updated.isCounter).toBe(true);
    expect(updated.version).toBe(2);

    const persisted = await db.tasks.get('standalone1');
    expect(persisted!.isCounter).toBe(true);
    expect(persisted!.version).toBe(2);

    const queued = await db.syncQueue.filter((q) => q.entityId === 'standalone1').toArray();
    expect(queued.length).toBeGreaterThan(0);
  });

  it('rejects a derived (linked) task', async () => {
    await db.tasks.add(counterMember());
    await expect(promoteTaskToCounter('member1')).rejects.toThrow();
  });

  it('rejects a non-counting task', async () => {
    await db.tasks.add({
      id: 'normal1',
      userId: 'u1',
      title: 'Do the dishes',
      type: TaskType.NORMAL,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    await expect(promoteTaskToCounter('normal1')).rejects.toThrow();
  });

  it('rejects a missing or deleted task', async () => {
    await expect(promoteTaskToCounter('does-not-exist')).rejects.toThrow();
    await db.tasks.add(standaloneCountingTask({ id: 'deleted1', isDeleted: true }));
    await expect(promoteTaskToCounter('deleted1')).rejects.toThrow();
  });
});

describe('deleteCounterWithUnlink (P5 decision 8)', () => {
  it('unlinks members with a snapshot event then soft-deletes the source', async () => {
    await db.tasks.add({
      id: 'src1',
      userId: 'u1',
      title: 'Push-ups (reps)',
      type: TaskType.COUNTING,
      action: 'Push-ups',
      unit: 'reps',
      isCounter: true,
      currentCount: 40,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    // member: baseline 10, maxCount 50 → displayed = 40 - 10 = 30
    await db.tasks.add(counterMember());

    await deleteCounterWithUnlink('src1');

    const member = await db.tasks.get('member1');
    expect(member).toBeDefined();
    expect(member!.sharedCounterId).toBeNull();
    expect(member!.baseline).toBeNull();
    expect(member!.currentCount).toBe(30);
    expect(member!.isDeleted).toBe(false);
    expect(member!.version).toBe(2);

    const memberEvents = await db.taskEvents.where('taskId').equals('member1').toArray();
    expect(memberEvents).toHaveLength(1);
    expect(memberEvents[0].delta).toBe(30);
    expect(memberEvents[0].occurredAt).not.toBe(SEED_EVENT_OCCURRED_AT);

    const source = await db.tasks.get('src1');
    expect(source).toBeDefined();
    expect(source!.isDeleted).toBe(true);
  });

  it('skips the snapshot event when the displayed value is 0', async () => {
    await db.tasks.add({
      id: 'src2',
      userId: 'u1',
      title: 'Push-ups (reps)',
      type: TaskType.COUNTING,
      action: 'Push-ups',
      unit: 'reps',
      isCounter: true,
      currentCount: 5,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    // baseline 10 > source count 5 → displayed clamps to 0
    await db.tasks.add(counterMember({ id: 'member2', sharedCounterId: 'src2', baseline: 10 }));

    await deleteCounterWithUnlink('src2');

    const member = await db.tasks.get('member2');
    expect(member!.currentCount).toBe(0);
    expect(member!.sharedCounterId).toBeNull();
    const memberEvents = await db.taskEvents.where('taskId').equals('member2').toArray();
    expect(memberEvents).toHaveLength(0);
  });

  it('is a no-op when the source is missing or already deleted', async () => {
    await expect(deleteCounterWithUnlink('does-not-exist')).resolves.toBeUndefined();
    await db.tasks.add({
      id: 'src3',
      userId: 'u1',
      title: 'gone',
      type: TaskType.COUNTING,
      isCounter: true,
      currentCount: 0,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: true,
    } as unknown as Task);
    await expect(deleteCounterWithUnlink('src3')).resolves.toBeUndefined();
    const source = await db.tasks.get('src3');
    expect(source!.isDeleted).toBe(true);
  });
});

describe('computeTaskDeletionImpact — counter members (P5)', () => {
  it('enumerates counter members for a source task', async () => {
    await db.tasks.add({
      id: 'src4',
      userId: 'u1',
      title: 'Push-ups (reps)',
      type: TaskType.COUNTING,
      action: 'Push-ups',
      unit: 'reps',
      isCounter: true,
      currentCount: 40,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);
    await db.tasks.add(counterMember({ id: 'member3', sharedCounterId: 'src4' }));

    const impact = await computeTaskDeletionImpact('src4');
    expect(impact.counterMemberCount).toBe(1);
    expect(impact.counterMembers).toHaveLength(1);
    expect(impact.counterMembers[0].id).toBe('member3');
  });

  it('reports zero members for a non-source task', async () => {
    await db.tasks.add(standaloneCountingTask());
    const impact = await computeTaskDeletionImpact('standalone1');
    expect(impact.counterMemberCount).toBe(0);
    expect(impact.counterMembers).toEqual([]);
  });
});

describe('createCompoundChild — goal-less counter guard (P5)', () => {
  it('rejects a flagged, goal-less counter as a compound child', async () => {
    await db.tasks.add({
      id: 'goalless1',
      userId: 'u1',
      title: 'Push-ups (reps)',
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
    } as unknown as Task);
    await db.tasks.add({
      id: 'parentCompound1',
      userId: 'u1',
      title: 'Morning routine',
      type: TaskType.COMPOUND,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);

    await expect(
      createCompoundChild({
        compoundTaskId: 'parentCompound1',
        childTaskId: 'goalless1',
        childIndex: 0,
      }),
    ).rejects.toThrow('createCompoundChild: goal-less counter tasks cannot be compound children');

    const children = await db.compoundChildren.where('compoundTaskId').equals('parentCompound1').toArray();
    expect(children).toHaveLength(0);
  });

  it('accepts a promoted (goaled) counter as a compound child', async () => {
    await db.tasks.add(standaloneCountingTask({ id: 'goaled1', isCounter: true }));
    await db.tasks.add({
      id: 'parentCompound2',
      userId: 'u1',
      title: 'Morning routine',
      type: TaskType.COMPOUND,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
    } as unknown as Task);

    const child = await createCompoundChild({
      compoundTaskId: 'parentCompound2',
      childTaskId: 'goaled1',
      childIndex: 0,
    });
    expect(child.childTaskId).toBe('goaled1');
  });
});

describe('createCompound — goal-less counter child guard (P5 review)', () => {
  it('rejects an existing goal-less counter referenced as a child', async () => {
    await db.tasks.add({
      id: 'goalless2',
      userId: 'u1',
      title: 'Push-ups (reps)',
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
    } as unknown as Task);

    await expect(
      createCompound('u1', {
        title: 'Morning routine',
        operator: OperatorType.AND,
        isOrdered: false,
        children: [{ childTaskId: 'goalless2' }],
      }),
    ).rejects.toThrow('createCompound: goal-less counter tasks cannot be compound children');

    // No partial writes: the parent compound task itself must not persist.
    const allTasks = await db.tasks.filter((t) => t.type === TaskType.COMPOUND).toArray();
    expect(allTasks).toHaveLength(0);
    const children = await db.compoundChildren.toArray();
    expect(children).toHaveLength(0);
  });

  it('accepts a promoted (goaled) counter referenced as a child', async () => {
    await db.tasks.add(standaloneCountingTask({ id: 'goaled2', isCounter: true }));

    const compound = await createCompound('u1', {
      title: 'Morning routine',
      operator: OperatorType.AND,
      isOrdered: false,
      children: [{ childTaskId: 'goaled2' }],
    });

    expect(compound.type).toBe(TaskType.COMPOUND);
    const children = await db.compoundChildren
      .where('compoundTaskId')
      .equals(compound.id)
      .toArray();
    expect(children).toHaveLength(1);
    expect(children[0].childTaskId).toBe('goaled2');
  });
});
