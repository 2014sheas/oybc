import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { applyStagedTaskEditsForWizardPersist } from '../wizardBoard';

const TABLES = () => [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue];
const NOW_ISO = '2026-10-07T12:00:00.000Z';

const seed = async (over: Partial<Task>): Promise<Task> => {
  const t = {
    id: 'r', userId: 'u1', title: 'Run 26.2 miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles',
    maxCount: 26.2, countKind: 'continuous', currentCount: 0, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: '2026-10-01T00:00:00.000Z', updatedAt: '2026-10-01T00:00:00.000Z', version: 1, isDeleted: false,
    ...over,
  } as Task;
  await db.tasks.add(t);
  return t;
};

afterEach(async () => {
  await Promise.all([db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(), db.boardTasks.clear(), db.compoundChildren.clear(), db.syncQueue.clear()]);
});

describe('applyStagedTaskEditsForWizardPersist — counter kinds', () => {
  it('a staged Discrete → Continuous switch and a decimal goal land together', async () => {
    await seed({ countKind: undefined, maxCount: 26, title: 'Run 26 miles' });
    await db.transaction('rw', TABLES(), () => applyStagedTaskEditsForWizardPersist(
      new Map([['r', { title: '', action: 'Run', goal: '26.2', unit: 'miles', children: [], countKind: 'continuous' }]]), new Set(), NOW_ISO, { strict: true }));
    expect(await db.tasks.get('r')).toMatchObject({ countKind: 'continuous', maxCount: 26.2, title: 'Run 26.2 miles' });
  });
  it('strict mode rejects a goal invalid at the staged kind and writes nothing', async () => {
    await seed({ countKind: undefined, maxCount: 26, title: 'Run 26 miles' });
    await expect(db.transaction('rw', TABLES(), () => applyStagedTaskEditsForWizardPersist(
      new Map([['r', { title: '', action: 'Run', goal: '26.2', unit: 'miles', children: [], countKind: 'discrete' }]]), new Set(), NOW_ISO, { strict: true })))
      .rejects.toThrow();
    expect((await db.tasks.get('r'))?.version).toBe(1);
  });
  it('a valid switch on r rolls back when a LATER staged edit fails strict mode', async () => {
    await seed({});
    const edits = new Map([
      ['r', { title: '', action: 'Run', goal: '26', unit: 'miles', children: [], countKind: 'discrete' as const }],
      ['gone', { title: 'x', action: '', goal: '', unit: '', children: [] }],
    ]);
    await expect(
      db.transaction('rw', TABLES(), () => applyStagedTaskEditsForWizardPersist(edits, new Set(), NOW_ISO, { strict: true })),
    ).rejects.toThrow();
    expect(await db.tasks.get('r')).toMatchObject({ countKind: 'continuous', maxCount: 26.2, version: 1 });
    expect(await db.syncQueue.count()).toBe(0);
  });
  it('a Continuous → Discrete switch rounds the stored row inside the same transaction', async () => {
    await seed({});
    await db.transaction('rw', TABLES(), () => applyStagedTaskEditsForWizardPersist(
      new Map([['r', { title: '', action: 'Run', goal: '26', unit: 'miles', children: [], countKind: 'discrete' }]]), new Set(), NOW_ISO, { strict: true }));
    expect(await db.tasks.get('r')).toMatchObject({ countKind: 'discrete', maxCount: 26, title: 'Run 26 miles' });
  });
});
