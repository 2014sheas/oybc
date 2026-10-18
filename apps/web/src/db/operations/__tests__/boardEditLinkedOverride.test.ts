import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { derivedTaskId, forkTaskId } from '@oybc/shared';
import { db } from '../../internal';
import { commitSquareEdits, type CommitSquareEditsInput } from '../boardEditCommit';
import type { SquareDraftCell } from '../../../hooks/squareEditCount';
import { JUNE, ROOT, SEPT, boardRow, clearAll, hubLinked, placement, rootTask } from './linkedCounterFixtures';

/**
 * Board Edit Save — a linked counter is placed AS-IS (TASK_WINDOW_REWORK
 * slice 3a: no per-board copy is minted); a staged "Edit task…" override's
 * parameter fields (goal, title) land on the placement, never the library row.
 */

const SEPT_ROW = derivedTaskId(SEPT.id, ROOT);

function cell(
  o: Partial<SquareDraftCell> & Pick<SquareDraftCell, 'cellId' | 'taskId' | 'row' | 'col'>,
): SquareDraftCell {
  return {
    isLocked: false,
    originalTaskId: o.taskId,
    originalRow: o.row,
    originalCol: o.col,
    originalLocked: false,
    ...o,
  };
}

function input(partial: Partial<CommitSquareEditsInput>): CommitSquareEditsInput {
  return {
    boardId: SEPT.id,
    cells: [],
    removedBoardTaskIds: [],
    taskOverrides: new Map(),
    isLegacyChosenOnDisk: false,
    centerCellKeepLocked: false,
    ...partial,
  };
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-09-10T00:00:00.000Z'));
  await db.tasks.put(rootTask());
  await db.boards.put(boardRow(SEPT));
});

afterEach(async () => {
  vi.useRealTimers();
  await clearAll();
});

describe('commitSquareEdits — overrides on linked counters', () => {
  it('replace-with-linked + override: the linked row is placed as-is, the override rides on the placement', async () => {
    await db.tasks.put(hubLinked('H', { title: 'Library title' }));
    await db.tasks.put(hubLinked('X', { sharedCounterId: undefined, title: 'Other' }));
    await db.boardTasks.put(placement('bt-1', SEPT.id, 'X'));

    await commitSquareEdits(
      input({
        cells: [cell({ cellId: 'bt-1', taskId: 'H', row: 0, col: 0, originalTaskId: 'X' })],
        taskOverrides: new Map([['H', { title: 'Edited on this board' }]]),
      }),
    );

    const bt = (await db.boardTasks.get('bt-1'))!;
    expect(bt.taskId).toBe('H');
    expect(bt.titleOverride).toBe('Edited on this board');
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
    expect((await db.tasks.get('H'))!.title).toBe('Library title');
  });

  it('add-linked + override: same on the add path', async () => {
    await db.tasks.put(hubLinked('H', { title: 'Library title' }));

    await commitSquareEdits(
      input({
        cells: [cell({ cellId: 'new-0-0-H', taskId: 'H', row: 0, col: 0, originalTaskId: null })],
        taskOverrides: new Map([['H', { title: 'Edited on this board' }]]),
      }),
    );

    const placed = (await db.boardTasks.where('boardId').equals(SEPT.id).toArray())[0];
    expect(placed.taskId).toBe('H');
    expect(placed.titleOverride).toBe('Edited on this board');
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
    expect((await db.tasks.get('H'))!.title).toBe('Library title');
  });

  it('a goal edit on a linked row writes targetOverride in the row\'s own kind and forks nothing', async () => {
    await db.tasks.put(hubLinked('H', { maxCount: 5 }));
    await db.boardTasks.put(placement('bt-h', SEPT.id, 'H'));
    await db.boardTasks.put(placement('bt-h2', JUNE.id, 'H'));
    await db.boards.put(boardRow(JUNE));

    await commitSquareEdits(
      input({
        cells: [cell({ cellId: 'bt-h', taskId: 'H', row: 0, col: 0 })],
        taskOverrides: new Map([['H', { maxCount: 9, action: 'Run', unit: 'miles', title: 'Run 9 miles' }]]),
      }),
    );

    expect(await db.boardTasks.get('bt-h')).toMatchObject({ taskId: 'H', targetOverride: 9, targetKind: 'discrete' });
    expect((await db.boardTasks.get('bt-h2'))!.targetOverride).toBeUndefined();
    expect((await db.tasks.get('H'))!).toMatchObject({ maxCount: 5, version: 2 });
    expect(await db.tasks.get(forkTaskId(SEPT.id, 'H'))).toBeUndefined();
  });

  it('a plain task override applies to the placement, not the task', async () => {
    await db.tasks.put(hubLinked('P', { sharedCounterId: undefined, title: 'Plain' }));
    await db.boardTasks.put(placement('bt-p', SEPT.id, 'P'));

    await commitSquareEdits(
      input({
        cells: [cell({ cellId: 'bt-p', taskId: 'P', row: 0, col: 0 })],
        taskOverrides: new Map([['P', { title: 'Plain edited' }]]),
      }),
    );

    expect((await db.tasks.get('P'))!.title).toBe('Plain');
    expect((await db.boardTasks.get('bt-p'))!.titleOverride).toBe('Plain edited');
  });
});
