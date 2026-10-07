import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { derivedTaskId, isWindowStampedDerived, TaskType, Timeframe } from '@oybc/shared';
import { db } from '../../internal';
import { addBoardTaskToBoard, updateBoardTaskAndCascade } from '../boardTasks';
import {
  JUNE,
  ROOT,
  SEPT,
  boardRow,
  clearAll,
  hubLinked,
  incEvent,
  placement,
  queued,
  rootTask,
} from './linkedCounterFixtures';

/**
 * Windowed linked counters — the placement choke points mint per-board rows.
 * Board Edit's add / replace square bypasses the wizard planner, so
 * `addBoardTaskToBoard` / `updateBoardTaskAndCascade` must resolve a linked
 * counter to THIS board's deterministic window-stamped row.
 */

const SEPT_TF = Timeframe.MONTHLY;
const SEPT_ROW = derivedTaskId(SEPT.id, ROOT);

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

describe('addBoardTaskToBoard — linked counters', () => {
  it('places the deterministic per-board row for a hub-linked task (with refreshed baseline)', async () => {
    await db.taskEvents.put(incEvent('e1', ROOT, 3, '2026-08-20T00:00:00.000Z'));
    await db.tasks.put(hubLinked('H'));

    const bt = await addBoardTaskToBoard(SEPT.id, 'H', 0, 0);

    expect(bt.taskId).toBe(SEPT_ROW);
    expect((await db.boardTasks.get(bt.id))!.taskId).toBe(SEPT_ROW);
    const row = (await db.tasks.get(SEPT_ROW))!;
    expect(isWindowStampedDerived(row)).toBe(true);
    expect(row.startDate).toBe(SEPT.startDate);
    expect(row.baseline).toBe(3);
    expect(await queued('tasks')).toContain(SEPT_ROW);
    // The hub-linked source is untouched.
    expect((await db.tasks.get('H'))!.startDate).toBeUndefined();
  });

  it('a placement copy of a continuous hub-linked row keeps its kind and fractional goal', async () => {
    await db.tasks.put(hubLinked('H', { countKind: 'continuous', maxCount: 2.5 }));

    await addBoardTaskToBoard(SEPT.id, 'H', 0, 0);

    const row = (await db.tasks.get(SEPT_ROW))!;
    expect(row.countKind).toBe('continuous');
    expect(row.maxCount).toBe(2.5);
  });

  it('places an already-stamped-for-this-board row as-is', async () => {
    await db.tasks.put(
      hubLinked('S', { createdInWizard: true, timeframe: SEPT_TF, startDate: SEPT.startDate, endDate: SEPT.endDate }),
    );
    const bt = await addBoardTaskToBoard(SEPT.id, 'S', 0, 0);
    expect(bt.taskId).toBe('S');
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
  });

  it('gives a row stamped for ANOTHER window a fresh copy for this board', async () => {
    await db.tasks.put(
      hubLinked('J', { createdInWizard: true, timeframe: SEPT_TF, startDate: JUNE.startDate, endDate: JUNE.endDate }),
    );
    const bt = await addBoardTaskToBoard(SEPT.id, 'J', 0, 0);
    expect(bt.taskId).toBe(SEPT_ROW);
    expect((await db.tasks.get('J'))!.startDate).toBe(JUNE.startDate);
  });

  it('reuses a live row and revives a tombstoned one', async () => {
    await db.tasks.put(hubLinked('H'));
    const first = await addBoardTaskToBoard(SEPT.id, 'H', 0, 0);
    const v = (await db.tasks.get(SEPT_ROW))!.version;
    await db.boardTasks.delete(first.id);
    const second = await addBoardTaskToBoard(SEPT.id, 'H', 0, 1);
    expect(second.taskId).toBe(SEPT_ROW);
    expect((await db.tasks.get(SEPT_ROW))!.version).toBe(v); // live → untouched

    await db.boardTasks.delete(second.id);
    await db.tasks.update(SEPT_ROW, { isDeleted: true, deletedAt: '2026-09-02T00:00:00.000Z' });
    const third = await addBoardTaskToBoard(SEPT.id, 'H', 1, 1);
    const revived = (await db.tasks.get(SEPT_ROW))!;
    expect(third.taskId).toBe(SEPT_ROW);
    expect(revived.isDeleted).toBe(false);
    expect(revived.version).toBe(v + 1);
  });

  it('leaves a non-COUNTING task carrying a sharedCounterId alone (type guard)', async () => {
    await db.tasks.put(hubLinked('N', { type: TaskType.NORMAL }));
    const bt = await addBoardTaskToBoard(SEPT.id, 'N', 0, 0);
    expect(bt.taskId).toBe('N');
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
  });

  it('places the ORIGINAL id when a live deterministic row exists but is not stamped for this board', async () => {
    // A live row at the deterministic id whose window is NOT this board's.
    await db.tasks.put(
      hubLinked(SEPT_ROW, { createdInWizard: true, timeframe: SEPT_TF, startDate: JUNE.startDate, endDate: JUNE.endDate }),
    );
    await db.tasks.put(hubLinked('H'));
    const bt = await addBoardTaskToBoard(SEPT.id, 'H', 0, 0);
    expect(bt.taskId).toBe('H');
    // The mismatched row is untouched.
    expect((await db.tasks.get(SEPT_ROW))!.startDate).toBe(JUNE.startDate);
  });

  it('leaves roots and plain counters alone', async () => {
    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0);
    expect(bt.taskId).toBe(ROOT);
  });
});

describe('updateBoardTaskAndCascade — linked counters', () => {
  it('replacing a square with a hub-linked task places the per-board row', async () => {
    await db.tasks.put(hubLinked('H'));
    await db.tasks.put(hubLinked('X', { sharedCounterId: undefined, title: 'Other' }));
    await db.boardTasks.put(placement('bt-1', SEPT.id, 'X'));

    await updateBoardTaskAndCascade('bt-1', 'H');

    const bt = (await db.boardTasks.get('bt-1'))!;
    expect(bt.taskId).toBe(SEPT_ROW);
    expect(bt.version).toBe(2);
    expect(isWindowStampedDerived((await db.tasks.get(SEPT_ROW))!)).toBe(true);
  });
});
