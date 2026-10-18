import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ROOT, SEPT, boardRow, clearAll, placement, queued, rootTask } from './linkedCounterFixtures';
import { db } from '../../internal';
import { setPlacementParams } from '../placementParams';

/**
 * TASK_WINDOW_REWORK slice 3a — `setPlacementParams`: the one writer of a
 * placement's per-board parameters. Merge, clear (field ABSENT so the
 * clearable-fields sync carries it), version bump, UPDATE enqueue, board
 * re-derive, sealed-board guard.
 */

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-09-10T00:00:00.000Z'));
  await db.tasks.put(rootTask({ maxCount: 100 }));
  await db.boards.put(boardRow(SEPT));
  await db.boardTasks.put(placement('bt-1', SEPT.id, ROOT));
});

afterEach(async () => {
  vi.useRealTimers();
  await clearAll();
});

describe('setPlacementParams', () => {
  it('sets a goal + kind, bumps the version and enqueues an UPDATE carrying the fields', async () => {
    await setPlacementParams('bt-1', { targetOverride: 30, targetKind: 'discrete' });

    const bt = (await db.boardTasks.get('bt-1'))!;
    expect(bt).toMatchObject({ targetOverride: 30, targetKind: 'discrete', version: 2 });
    const items = (await db.syncQueue.toArray()).filter((i) => i.entityType === 'boardTasks' && i.entityId === 'bt-1');
    expect(items).toHaveLength(1);
    expect(items[0].operationType).toBe('update');
    expect(JSON.parse(items[0].payload)).toMatchObject({ targetOverride: 30, targetKind: 'discrete', version: 2 });
  });

  it('merges: a later title patch keeps the goal, and childTargets are stored sorted', async () => {
    await setPlacementParams('bt-1', { targetOverride: 30, targetKind: 'discrete' });
    await setPlacementParams('bt-1', {
      titleOverride: '  Thirty  ',
      childTargets: [{ childId: 'b', target: 2 }, { childId: 'a', target: 1 }],
    });

    expect(await db.boardTasks.get('bt-1')).toMatchObject({
      targetOverride: 30,
      targetKind: 'discrete',
      titleOverride: 'Thirty',
      childTargets: [{ childId: 'a', target: 1 }, { childId: 'b', target: 2 }],
      version: 3,
    });
  });

  it('null clears: the field is ABSENT on the row, and clearing the goal clears its kind', async () => {
    await setPlacementParams('bt-1', { targetOverride: 30, targetKind: 'discrete', titleOverride: 'Thirty' });
    await setPlacementParams('bt-1', { targetOverride: null, titleOverride: null });

    const bt = (await db.boardTasks.get('bt-1'))!;
    for (const k of ['targetOverride', 'targetKind', 'titleOverride', 'childTargets']) expect(k in bt).toBe(false);
    expect(bt.version).toBe(3);
  });

  it('a patch that changes nothing writes nothing (no version bump, no enqueue)', async () => {
    await setPlacementParams('bt-1', { targetOverride: 30, targetKind: 'discrete' });
    const before = (await queued('boardTasks')).length;

    await setPlacementParams('bt-1', { targetOverride: 30, targetKind: 'discrete' });
    await setPlacementParams('bt-1', { titleOverride: null });

    expect((await db.boardTasks.get('bt-1'))!.version).toBe(2);
    expect((await queued('boardTasks')).length).toBe(before);
  });

  it('joins the caller\'s transaction: a throw after it rolls the write back', async () => {
    await expect(
      db.transaction(
        'rw',
        [db.boardTasks, db.boards, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
        async () => {
          await setPlacementParams('bt-1', { targetOverride: 30, targetKind: 'discrete' });
          throw new Error('abort');
        },
      ),
    ).rejects.toThrow('abort');
    expect((await db.boardTasks.get('bt-1'))!.version).toBe(1);
    expect(await queued('boardTasks')).toEqual([]);
  });

  it('is a no-op for a sealed board, a deleted placement and an unknown id', async () => {
    await db.boards.update(SEPT.id, { sealedAt: '2026-09-09T00:00:00.000Z' });
    await setPlacementParams('bt-1', { targetOverride: 30, targetKind: 'discrete' });
    expect((await db.boardTasks.get('bt-1'))!.targetOverride).toBeUndefined();

    await db.boards.update(SEPT.id, { sealedAt: undefined });
    await db.boardTasks.update('bt-1', { isDeleted: true });
    await setPlacementParams('bt-1', { targetOverride: 30, targetKind: 'discrete' });
    await setPlacementParams('missing', { titleOverride: 'x' });
    expect((await db.boardTasks.get('bt-1'))!.targetOverride).toBeUndefined();
  });

  it('re-derives the board: a goal lowered below the logged count completes the square', async () => {
    await db.taskEvents.put({
      id: 'e1', userId: 'user-1', taskId: ROOT, kind: 'increment', delta: 12,
      occurredAt: '2026-09-05T00:00:00.000Z', createdAt: '2026-09-05T00:00:00.000Z',
      updatedAt: '2026-09-05T00:00:00.000Z', version: 1, isDeleted: false,
    });
    expect((await db.boards.get(SEPT.id))!.completedTasks).toBe(0);

    await setPlacementParams('bt-1', { targetOverride: 10, targetKind: 'discrete' });

    expect((await db.boards.get(SEPT.id))!.completedTasks).toBe(1);
  });
});
