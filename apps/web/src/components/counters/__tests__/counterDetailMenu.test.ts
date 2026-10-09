import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { db } from '../../../db/internal';
import { saveTaskEdit } from '../../../db/operations/compoundStructureEdit';
import { loadSharedCounterGroups } from '../../../hooks/useSharedCounterGroups';
import { counterDetailMenuItems, editableCounterRoot } from '../counterDetailMenu';

const T0 = '2026-10-01T00:00:00.000Z';

const root = (over: Partial<Task> = {}): Task =>
  ({
    id: 'root', userId: 'u1', title: 'Run miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles',
    isCounter: true, countKind: 'discrete', currentCount: 12, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
    ...over,
  }) as Task;

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(), db.boardTasks.clear(),
    db.compoundChildren.clear(), db.syncQueue.clear(),
  ]);
});

describe('counterDetailMenuItems', () => {
  it('lists "Edit counter…" then "Delete counter…" when the root is live', () => {
    const onEdit = vi.fn();
    const onDelete = vi.fn();
    const items = counterDetailMenuItems({ root: root(), onEdit, onDelete });
    expect(items.map((i) => i.label)).toEqual(['Edit counter…', 'Delete counter…']);
    items[0].action();
    expect(onEdit).toHaveBeenCalledWith(expect.objectContaining({ id: 'root' }));
    items[1].action();
    expect(onDelete).toHaveBeenCalledTimes(1);
    expect(items[1].destructive).toBe(true);
  });

  it('omits "Edit counter…" when the root is missing or deleted', () => {
    const args = { onEdit: vi.fn(), onDelete: vi.fn() };
    expect(counterDetailMenuItems({ ...args, root: null }).map((i) => i.label)).toEqual(['Delete counter…']);
    expect(editableCounterRoot(undefined)).toBeNull();
    expect(editableCounterRoot(root({ isDeleted: true }))).toBeNull();
    expect(editableCounterRoot(root())?.id).toBe('root');
  });
});

describe('Edit counter… → saveTaskEdit on the root', () => {
  it('a kind switch reaches the hub group and the live copy (D5)', async () => {
    await db.tasks.add(root());
    await db.tasks.add(root({ id: 'copy', isCounter: false, sharedCounterId: 'root', maxCount: 10, title: 'Run 10 miles', currentCount: 0 }));
    expect((await loadSharedCounterGroups('u1', false)).find((g) => g.counterId === 'root')?.countKind).toBe('discrete');

    await saveTaskEdit('root', { countKind: 'continuous', title: 'Jog miles', action: 'Jog', unit: 'miles' });

    const group = (await loadSharedCounterGroups('u1', false)).find((g) => g.counterId === 'root');
    expect(group).toMatchObject({ countKind: 'continuous', action: 'Jog' });
    expect(await db.tasks.get('copy')).toMatchObject({ countKind: 'continuous', action: 'Jog' });
  });
});
