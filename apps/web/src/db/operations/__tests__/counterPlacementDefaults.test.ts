import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CenterSquareType, Timeframe, derivedTaskId, withPlacementParams, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { addBoardTaskToBoard, updateBoardTaskAndCascade } from '../boardTasks';
import { persistWizardBoardRows, type PersistWizardBoardRowsInput } from '../wizardBoard';
import { ROOT, SEPT, USER, boardRow, clearAll, hubLinked, placement, rootTask } from './linkedCounterFixtures';

/**
 * docs/SHARED_COUNTER_SETTINGS.md §2 + TASK_WINDOW_REWORK slice 3a — the
 * Board Edit placement choke points (add + Replace) place a counter ROOT as-is
 * and carry the counter's default goal for the board's timeframe as the
 * placement's `targetOverride` + `targetKind` (no per-board copy is minted); a
 * linked task is placed with no parameters. Slice 3b: the wizard's persist
 * (hand-added and pool-pulled roots) places parameters the same way.
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
  await db.pools.clear();
});

describe('Board Edit placement — a counter root with a timeframe default', () => {
  it('add: places the root AS-IS with the default as targetOverride (no copy is minted)', async () => {
    await db.tasks.put(withDefaults());

    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0);

    expect(bt).toMatchObject({ taskId: ROOT, targetOverride: 30, targetKind: 'discrete' });
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
    const stored = (await db.boardTasks.get(bt.id))!;
    expect(stored).toMatchObject({ taskId: ROOT, targetOverride: 30, targetKind: 'discrete' });
    // The root keeps its own goal and title; the square reads the placement.
    const root = (await db.tasks.get(ROOT))!;
    expect(root.maxCount).toBe(100);
    expect(withPlacementParams(root, stored).maxCount).toBe(30);
    expect(withPlacementParams(root, stored).title).toBe('Run 30 mi');
  });

  it('replace: the replacement carries the default as a parameter; the old parameters are dropped', async () => {
    await db.tasks.put(withDefaults());
    await db.tasks.put(hubLinked('X', { sharedCounterId: undefined, title: 'Other' }));
    await db.boardTasks.put({ ...placement('bt-1', SEPT.id, 'X'), titleOverride: 'Old name', targetOverride: 4 });

    await updateBoardTaskAndCascade('bt-1', ROOT);

    const bt = (await db.boardTasks.get('bt-1'))!;
    expect(bt).toMatchObject({ taskId: ROOT, targetOverride: 30, targetKind: 'discrete', version: 2 });
    expect(bt.titleOverride).toBeUndefined();
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
  });

  it('no defaults: the root is placed with no parameters, exactly as before', async () => {
    await db.tasks.put(rootTask({ titleTemplatePlural: 'Run #N mi' }));
    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0);
    expect(bt.taskId).toBe(ROOT);
    expect(bt.targetOverride).toBeUndefined();
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
  });

  it('a default equal to the root goal writes no override', async () => {
    await db.tasks.put(rootTask({ timeframeGoals: { monthly: 100 } }));
    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0);
    expect(bt.taskId).toBe(ROOT);
    expect(bt.targetOverride).toBeUndefined();
    expect(bt.targetKind).toBeUndefined();
  });

  it('explicit placement parameters win over the default rule', async () => {
    await db.tasks.put(withDefaults());

    const bt = await addBoardTaskToBoard(SEPT.id, ROOT, 0, 0, {
      placement: { targetOverride: 12, targetKind: 'discrete', titleOverride: 'Twelve' },
    });

    expect(bt).toMatchObject({ taskId: ROOT, targetOverride: 12, targetKind: 'discrete', titleOverride: 'Twelve' });
    expect((await db.boardTasks.get(bt.id))!.targetOverride).toBe(12);
  });
});

describe('Board Edit placement — a linked task', () => {
  it('is placed as-is with no parameters (it keeps its own goal and title)', async () => {
    await db.tasks.put(withDefaults());
    await db.tasks.put(hubLinked('H', { title: 'Run 10 miles', maxCount: 10 }));

    const bt = await addBoardTaskToBoard(SEPT.id, 'H', 0, 0);

    expect(bt.taskId).toBe('H');
    expect(bt.targetOverride).toBeUndefined();
    expect(bt.titleOverride).toBeUndefined();
    expect(await db.tasks.get(SEPT_ROW)).toBeUndefined();
    expect((await db.tasks.get('H'))!.maxCount).toBe(10);
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

  it('places the root AS-IS with the weekly default as its override; the square reads the templated title', async () => {
    const root = rootTask({
      timeframeGoals: { weekly: 7 },
      titleTemplateSingular: 'Run #N mile',
      titleTemplatePlural: 'Run #N mi',
    });
    await db.tasks.put(root);

    const boardId = await persistWizardBoardRows(input(root));

    const placed = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(placed.map((p) => p.taskId)).toEqual([ROOT]);
    expect(placed[0]).toMatchObject({ targetOverride: 7, targetKind: 'discrete' });
    expect(await db.tasks.count()).toBe(1);
    expect(withPlacementParams(root, placed[0]).title).toBe('Run 7 mi');
  });

  it('a POOL-pulled root takes its weekly default too (a source pull and a hand-add agree)', async () => {
    const root = rootTask({ timeframeGoals: { weekly: 3 }, titleTemplatePlural: 'Run #N mi' });
    await db.tasks.put(root);
    await db.pools.add({
      id: 'pool-1', userId: USER, name: 'Runs', taskIds: [ROOT],
      createdAt: WEEK_START, updatedAt: WEEK_START, version: 1, isDeleted: false,
    });

    const boardId = await persistWizardBoardRows({
      ...input(root),
      manualTaskIds: [],
      sources: [{ sourceId: 'pool-1', kind: 'pool', min: 0, max: null, excludedTaskIds: [], filter: 'all' }],
    });

    const placed = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(placed.map((p) => p.taskId)).toEqual([ROOT]);
    expect(placed[0]).toMatchObject({ targetOverride: 3, targetKind: 'discrete' });
    expect(await db.tasks.count()).toBe(1);
    expect(withPlacementParams(root, placed[0]).title).toBe('Run 3 mi');
  });

  it('an explicit wizard parameter wins over the planner\'s default for that cell', async () => {
    const root = rootTask({ timeframeGoals: { weekly: 7 }, titleTemplatePlural: 'Run #N mi' });
    await db.tasks.put(root);

    const boardId = await persistWizardBoardRows({
      ...input(root),
      placementParams: { [ROOT]: { targetOverride: 12, targetKind: 'discrete' } },
    });

    const placed = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(placed[0]).toMatchObject({ taskId: ROOT, targetOverride: 12, targetKind: 'discrete' });
  });

  it('a DRAFT save places the original id with no parameters (planned at the activating save)', async () => {
    const root = rootTask({ timeframeGoals: { weekly: 7 } });
    await db.tasks.put(root);

    const boardId = await persistWizardBoardRows({
      ...input(root),
      status: 'draft',
      placementParams: { [ROOT]: { targetOverride: 12, targetKind: 'discrete' } },
    });

    const placed = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(placed.map((p) => p.taskId)).toEqual([ROOT]);
    expect(placed[0].targetOverride).toBeUndefined();
  });

  it('no defaults: the root itself is placed, exactly as before', async () => {
    const root = rootTask();
    await db.tasks.put(root);

    const boardId = await persistWizardBoardRows(input(root));

    const placed = await db.boardTasks.where('boardId').equals(boardId).toArray();
    expect(placed.map((p) => p.taskId)).toEqual([ROOT]);
  });
});
