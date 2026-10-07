import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { TaskType, type CountKind } from '@oybc/shared';
import { db } from '../../internal';
import { commitSquareEdits } from '../boardEditCommit';
import { KindGoalError } from '../countKindSwitch';
import type { SquareDraftCell } from '../../../hooks/squareEditCount';
import { seedDraft, stageTaskEdit, type BoardEditTaskOverride } from '../../../hooks/squaresEditReducer';
import { CenterSquareType } from '@oybc/shared';
import { ROOT, SEPT, boardRow, clearAll, placement, rootTask } from './linkedCounterFixtures';

/**
 * Board Edit Save with a staged kind switch (Review Focus 4): the switch runs
 * inside the Save's one transaction, then the typed goal wins; a goal the new
 * kind refuses rolls the WHOLE Save back.
 */

async function seedBoardWithCounter(o: { type?: TaskType; maxCount?: number; countKind?: CountKind }): Promise<{
  boardId: string;
  rootId: string;
  cells: SquareDraftCell[];
}> {
  const type = o.type ?? TaskType.COUNTING;
  await db.boards.put(boardRow(SEPT));
  await db.tasks.put(
    type === TaskType.COUNTING
      ? rootTask({ maxCount: o.maxCount ?? 100, countKind: o.countKind, title: `Run ${o.maxCount ?? 100} miles` })
      : rootTask({ type, title: 'Practice', action: undefined, unit: undefined, maxCount: undefined, currentCount: undefined, countKind: o.countKind }),
  );
  await db.boardTasks.put(placement('bt-0', SEPT.id, ROOT));
  const cells: SquareDraftCell[] = [
    { cellId: 'bt-0', taskId: ROOT, row: 0, col: 0, isLocked: false, originalTaskId: ROOT, originalRow: 0, originalCol: 0, originalLocked: false },
  ];
  return { boardId: SEPT.id, rootId: ROOT, cells };
}

const commit = (boardId: string, cells: SquareDraftCell[], taskId: string, override: BoardEditTaskOverride) =>
  commitSquareEdits({
    boardId, cells, removedBoardTaskIds: [], taskOverrides: new Map([[taskId, override]]),
    isLegacyChosenOnDisk: false, centerCellKeepLocked: false,
  });

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-09-10T00:00:00.000Z'));
});

afterEach(async () => {
  vi.useRealTimers();
  await clearAll();
});

describe('commitSquareEdits — staged kind switch', () => {
  it('kind switch then goal edit, atomic (Review Focus 4)', async () => {
    const { boardId, rootId, cells } = await seedBoardWithCounter({ maxCount: 26.2, countKind: 'continuous' });
    await commit(boardId, cells, rootId, { countKind: 'discrete', maxCount: 30, action: 'Run', unit: 'mi', title: 'Run 30 mi' });
    expect(await db.tasks.get(rootId)).toMatchObject({ countKind: 'discrete', maxCount: 30, title: 'Run 30 mi' });
  });

  it('a fractional goal at the new whole kind rolls the whole Save back', async () => {
    const { boardId, rootId, cells } = await seedBoardWithCounter({ maxCount: 26.2, countKind: 'continuous' });
    await expect(commit(boardId, cells, rootId, { countKind: 'discrete', maxCount: 26.5, title: 'x' })).rejects.toBeInstanceOf(KindGoalError);
    expect(await db.tasks.get(rootId)).toMatchObject({ countKind: 'continuous', maxCount: 26.2, version: 1 });
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('a Simple square converted to Counting saves the chosen kind', async () => {
    const { boardId, rootId, cells } = await seedBoardWithCounter({ type: TaskType.NORMAL });
    await commit(boardId, cells, rootId, { type: TaskType.COUNTING, countKind: 'duration', action: 'Practice', unit: '', maxCount: 90, title: 'Practice 1h 30m' });
    expect(await db.tasks.get(rootId)).toMatchObject({ type: TaskType.COUNTING, countKind: 'duration', maxCount: 90 });
  });

  it('a Counting square switched to Simple leaves its kind untouched (never cleared — sync merge-writes)', async () => {
    const { boardId, rootId, cells } = await seedBoardWithCounter({ maxCount: 26.2, countKind: 'continuous' });
    await commit(boardId, cells, rootId, { type: TaskType.NORMAL, title: 'Run', action: undefined, unit: undefined, maxCount: undefined });
    expect(await db.tasks.get(rootId)).toMatchObject({ type: TaskType.NORMAL, countKind: 'continuous' });
  });

  it('a Simple row carrying a stale Continuous kind, converted to Counting as Discrete, writes Discrete explicitly', async () => {
    const { boardId, rootId, cells } = await seedBoardWithCounter({ type: TaskType.NORMAL, countKind: 'continuous' });
    await commit(boardId, cells, rootId, { type: TaskType.COUNTING, countKind: 'discrete', action: 'Run', unit: 'miles', maxCount: 30, title: 'Run 30 miles' });
    const row = await db.tasks.get(rootId);
    expect(row).toMatchObject({ type: TaskType.COUNTING, countKind: 'discrete', maxCount: 30 });
    const queued = (await db.syncQueue.toArray()).filter((i) => i.entityId === rootId);
    expect(JSON.parse(queued[queued.length - 1]?.payload ?? '{}')).toMatchObject({ countKind: 'discrete' });
  });

  it('a staged kind switch discarded by Cancel (the draft re-seeds) writes nothing', async () => {
    const { rootId } = await seedBoardWithCounter({ maxCount: 26.2, countKind: 'continuous' });
    const placed = await db.boardTasks.toArray();
    const staged = stageTaskEdit(seedDraft(placed, CenterSquareType.FREE, 3), rootId, { countKind: 'discrete', maxCount: 26 });
    expect(staged.taskOverrides.size).toBe(1);
    // Cancel → Discard drops the session; re-entering Edit re-seeds from the DB.
    const reseeded = seedDraft(placed, CenterSquareType.FREE, 3);
    expect(reseeded.taskOverrides.size).toBe(0);
    expect(await db.tasks.get(rootId)).toMatchObject({ countKind: 'continuous', maxCount: 26.2, version: 1 });
    expect(await db.syncQueue.count()).toBe(0);
  });
});
