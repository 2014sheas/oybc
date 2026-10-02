import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { derivedTaskId } from '@oybc/shared';
import { db } from '../../internal';
import { commitSquareEdits, type CommitSquareEditsInput } from '../boardEditCommit';
import type { SquareDraftCell } from '../../../hooks/squareEditCount';
import { ROOT, SEPT, boardRow, clearAll, hubLinked, placement, rootTask } from './linkedCounterFixtures';

/**
 * Board Edit Save — a linked counter lands as its per-board window-stamped
 * copy, so a staged "Edit task…" override (keyed by the STAGED library id)
 * must be remapped onto the placed copy; the library source is never patched.
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
  it('replace-with-linked + override: the per-board copy carries the override, the library source is untouched', async () => {
    await db.tasks.put(hubLinked('H', { title: 'Library title' }));
    await db.tasks.put(hubLinked('X', { sharedCounterId: undefined, title: 'Other' }));
    await db.boardTasks.put(placement('bt-1', SEPT.id, 'X'));

    await commitSquareEdits(
      input({
        cells: [cell({ cellId: 'bt-1', taskId: 'H', row: 0, col: 0, originalTaskId: 'X' })],
        taskOverrides: new Map([['H', { title: 'Edited on this board' }]]),
      }),
    );

    expect((await db.boardTasks.get('bt-1'))!.taskId).toBe(SEPT_ROW);
    expect((await db.tasks.get(SEPT_ROW))!.title).toBe('Edited on this board');
    expect((await db.tasks.get('H'))!.title).toBe('Library title');
  });

  it('add-linked + override: same remap on the add path', async () => {
    await db.tasks.put(hubLinked('H', { title: 'Library title' }));

    await commitSquareEdits(
      input({
        cells: [cell({ cellId: 'new-0-0-H', taskId: 'H', row: 0, col: 0, originalTaskId: null })],
        taskOverrides: new Map([['H', { title: 'Edited on this board' }]]),
      }),
    );

    const placed = (await db.boardTasks.where('boardId').equals(SEPT.id).toArray())[0];
    expect(placed.taskId).toBe(SEPT_ROW);
    expect((await db.tasks.get(SEPT_ROW))!.title).toBe('Edited on this board');
    expect((await db.tasks.get('H'))!.title).toBe('Library title');
  });

  it('a plain task override applies to that task as before', async () => {
    await db.tasks.put(hubLinked('P', { sharedCounterId: undefined, title: 'Plain' }));
    await db.boardTasks.put(placement('bt-p', SEPT.id, 'P'));

    await commitSquareEdits(
      input({
        cells: [cell({ cellId: 'bt-p', taskId: 'P', row: 0, col: 0 })],
        taskOverrides: new Map([['P', { title: 'Plain edited' }]]),
      }),
    );

    expect((await db.tasks.get('P'))!.title).toBe('Plain edited');
  });
});
