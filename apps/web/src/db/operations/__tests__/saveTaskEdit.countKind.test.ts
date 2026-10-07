import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { saveTaskEdit } from '../compoundStructureEdit';
import { KindGoalError } from '../countKindSwitch';

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

describe('saveTaskEdit — counter kinds', () => {
  it('switches continuous → discrete then applies the typed goal', async () => {
    await seed({});
    await saveTaskEdit('r', { countKind: 'discrete', maxCount: 30, action: 'Run', unit: 'miles', title: 'Run 30 miles' });
    expect(await db.tasks.get('r')).toMatchObject({ countKind: 'discrete', maxCount: 30, title: 'Run 30 miles' });
  });
  it('a fractional goal at the new whole kind rolls the switch back', async () => {
    await seed({});
    await expect(saveTaskEdit('r', { countKind: 'discrete', maxCount: 26.5, title: 'Run 26.5 miles' })).rejects.toBeInstanceOf(KindGoalError);
    expect(await db.tasks.get('r')).toMatchObject({ countKind: 'continuous', maxCount: 26.2, version: 1 });
    expect(await db.syncQueue.count()).toBe(0);
  });
  it('an unchanged kind is one ordinary version bump', async () => {
    await seed({ countKind: undefined, maxCount: 5, title: 'Read 5 pages', unit: 'pages', action: 'Read' });
    await saveTaskEdit('r', { countKind: 'discrete', maxCount: 6, title: 'Read 6 pages' });
    expect((await db.tasks.get('r'))?.version).toBe(2);
  });
});
