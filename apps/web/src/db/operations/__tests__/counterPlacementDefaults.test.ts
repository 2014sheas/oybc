import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CenterSquareType, Timeframe, derivedTaskId, isWindowStampedDerived, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { addBoardTaskToBoard, updateBoardTaskAndCascade } from '../boardTasks';
import { persistWizardBoardRows, type PersistWizardBoardRowsInput } from '../wizardBoard';
import { ROOT, SEPT, USER, boardRow, clearAll, hubLinked, placement, rootTask } from './linkedCounterFixtures';

/**
 * docs/SHARED_COUNTER_SETTINGS.md §2 (PR 2) — placing a shared counter mints
 * its per-board copy at the counter's default goal for the board's timeframe,
 * titled through the root's templates. A counter with no defaults places
 * exactly as before. Covers both mint paths: Board Edit (add + Replace via the
 * placement choke points) and the wizard's hand-added branch (persist).
 */

const SEPT_ROW = derivedTaskId(SEPT.id, ROOT);
/** SEPT is a MONTHLY board — a monthly default of 30 for a 100-mile counter. */
const withDefaults = (over: Partial<Task> = {}): Task =>
  rootTask({ timeframeGoals: { monthly: 30 }, titleTemplatePlural: 'Run #N mi', ...over });

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date('2026-09-10T00:00:00.000Z'));
  await db.boards.put(boardRow(SEPT));
});

afterEach(async () => {
  vi.useRealTimers();
  await clearAll();
});

describe('Board Edit placement — a counter root with a timeframe default', () => {
  it('add: mints the per-board copy at the default, titled from the root template', async () => {
    await db.tasks.put(withDefaults());

    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0);

    expect(bt.taskId).toBe(SEPT_ROW);
    const row = (await db.tasks.get(SEPT_ROW))!;
    expect(row.maxCount).toBe(30);
    expect(row.title).toBe('Run 30 mi');
    expect(row.sharedCounterId).toBe(ROOT);
    expect(isWindowStampedDerived(row)).toBe(true);
    expect(row.startDate).toBe(SEPT.startDate);
  });

  it('replace: the replacement copy carries the default too', async () => {
    await db.tasks.put(withDefaults());
    await db.tasks.put(hubLinked('X', { sharedCounterId: undefined, title: 'Other' }));
    await db.boardTasks.put(placement('bt-1', SEPT.id, 'X'));

    await updateBoardTaskAndCascade('bt-1', ROOT);

    expect((await db.boardTasks.get('bt-1'))!.taskId).toBe(SEPT_ROW);
    expect((await db.tasks.get(SEPT_ROW))!.maxCount).toBe(30);
  });

  it('no defaults: the root itself is placed, exactly as before', async () => {
    await db.tasks.put(rootTask({ titleTemplatePlural: 'Run #N mi' }));
    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0);
    expect(bt.taskId).toBe(ROOT);
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
  });

  it('a default equal to the root goal places the root (no identical clone)', async () => {
    await db.tasks.put(rootTask({ timeframeGoals: { monthly: 100 } }));
    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0);
    expect(bt.taskId).toBe(ROOT);
  });

  it('a revived copy keeps its own goal', async () => {
    await db.tasks.put(withDefaults());
    await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0);
    await db.tasks.update(SEPT_ROW, { maxCount: 12, isDeleted: true, deletedAt: '2026-09-09T00:00:00.000Z' });
    await db.boardTasks.where('boardId').equals(SEPT.id).modify({ isDeleted: true });

    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 1);

    expect(bt.taskId).toBe(SEPT_ROW);
    const row = (await db.tasks.get(SEPT_ROW))!;
    expect(row.isDeleted).toBe(false);
    expect(row.maxCount).toBe(12);
  });
});

describe('Board Edit placement — a linked task', () => {
  it('keeps its own goal; its copy title renders through the root template', async () => {
    await db.tasks.put(withDefaults());
    await db.tasks.put(hubLinked('H', { title: 'Run 10 miles', maxCount: 10 }));

    const bt = await addBoardTaskToBoard(SEPT.id, 'H', 0, 0);

    const row = (await db.tasks.get(bt.taskId))!;
    expect(bt.taskId).toBe(SEPT_ROW);
    expect(row.maxCount).toBe(10);
    expect(row.title).toBe('Run 10 mi');
  });
});

describe('Wizard hand-add — a counter root with a timeframe default', () => {
  const WEEK_START = '2026-09-07T00:00:00';
  const input = (root: Task): PersistWizardBoardRowsInput => ({
    userId: USER,
    draftBoardId: null,
    isCore: false,
    isRecurringDraft: false,
    status: 'active',
    boardFields: {
      name: 'Week',
      boardSize: 3,
      timeframe: Timeframe.WEEKLY,
      startDate: WEEK_START,
      endDate: '2026-09-13T23:59:59',
      centerSquareType: CenterSquareType.NONE,
      isRandomized: false,
    },
    placement: [root, ...new Array(8).fill(null)],
    size: 3,
    centerType: CenterSquareType.NONE,
    pendingTasks: [],
    manualTaskIds: [ROOT],
  });

  it('mints the copy at the weekly default with the templated title', async () => {
    const root = rootTask({
      timeframeGoals: { weekly: 7 },
      titleTemplateSingular: 'Run #N mile',
      titleTemplatePlural: 'Run #N mi',
    });
    await db.tasks.put(root);

    const boardId = await persistWizardBoardRows(input(root));

    const placed = await db.boardTasks.where('boardId').equals(boardId).toArray();
    const copyId = derivedTaskId(boardId, ROOT);
    expect(placed.map((p) => p.taskId)).toEqual([copyId]);
    const row = (await db.tasks.get(copyId))!;
    expect(row.maxCount).toBe(7);
    expect(row.title).toBe('Run 7 mi');
  });

  it('no defaults: the root itself is placed, exactly as before', async () => {
    const root = rootTask();
    await db.tasks.put(root);

    const boardId = await persistWizardBoardRows(input(root));

    const placed = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(placed.map((p) => p.taskId)).toEqual([ROOT]);
  });
});
