import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import { saveTaskEdit } from '../compoundStructureEdit';

/**
 * Board-scoped task edits PR 3 (docs/BOARD_SCOPED_TASK_EDITS.md §6): a hub
 * root's Task Detail edit propagates title / action / unit to its LIVE
 * per-board copies — never the goal, never a frozen / deleted / sealed-board
 * copy — with one authored write (version bump + enqueue) per changed copy.
 * iOS twin: `AppDatabaseRootFieldPropagationTests`.
 */

const USER = 'user-1';
const NOW = new Date('2026-10-08T12:00:00.000Z');
const SEEDED = '2026-10-01T08:00:00.000Z';
const ROOT = 'root';
const LIVE_WINDOW = { startDate: '2026-10-05T00:00:00.000Z', endDate: '2026-10-11T23:59:59.999Z' };
const ENDED_WINDOW = { startDate: '2026-09-28T00:00:00.000Z', endDate: '2026-10-04T23:59:59.999Z' };

function counting(id: string, over: Partial<Task>): Task {
  return {
    id,
    userId: USER,
    title: 'Run 26 miles',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'miles',
    maxCount: 26,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function copy(id: string, maxCount: number, window: typeof LIVE_WINDOW, over: Partial<Task> = {}): Task {
  return counting(id, {
    title: `Run ${maxCount} miles`,
    maxCount,
    sharedCounterId: ROOT,
    baseline: 0,
    createdInWizard: true,
    timeframe: Timeframe.WEEKLY,
    version: 4,
    ...window,
    ...over,
  });
}

async function seedBoard(id: string, window: typeof LIVE_WINDOW, taskId: string, sealedAt?: string): Promise<void> {
  const board: Board = {
    id,
    userId: USER,
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    ...window,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
    ...(sealedAt ? { sealedAt, sealedCompletedCells: [] } : {}),
  } as Board;
  await db.boards.add(board);
  const bt: BoardTask = {
    id: `bt-${id}`,
    boardId: id,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

/** Root + live / frozen / deleted / sealed-board copies, each placed on its own board. */
async function seedFamily(rootOver: Partial<Task> = {}, liveOver: Partial<Task> = {}): Promise<void> {
  await db.tasks.add(counting(ROOT, { isCounter: true, ...rootOver }));
  await db.tasks.add(copy('c-live', 10, LIVE_WINDOW, liveOver));
  await db.tasks.add(copy('c-frozen', 8, ENDED_WINDOW));
  await db.tasks.add(copy('c-deleted', 9, LIVE_WINDOW, { isDeleted: true, deletedAt: SEEDED }));
  await db.tasks.add(copy('c-sealed', 7, LIVE_WINDOW));
  await seedBoard('b-live', LIVE_WINDOW, 'c-live');
  await seedBoard('b-frozen', ENDED_WINDOW, 'c-frozen');
  await seedBoard('b-sealed', LIVE_WINDOW, 'c-sealed', '2026-10-07T12:00:00.000Z');
}

async function queuedTaskIds(): Promise<string[]> {
  const items = await db.syncQueue.where('entityType').equals('tasks').toArray();
  return items.map((i) => i.entityId).sort();
}

async function expectUntouched(id: string, title: string, version = 4): Promise<void> {
  expect(await db.tasks.get(id)).toMatchObject({ title, action: 'Run', unit: 'miles', version });
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(NOW);
});

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all([
    db.tasks.clear(),
    db.taskEvents.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('saveTaskEdit — root → copy propagation', () => {
  it('an action change regenerates the live copy auto title from its own goal; goal and other copies untouched', async () => {
    await seedFamily();
    await saveTaskEdit(ROOT, { title: 'Jog 30 miles', action: 'Jog', unit: 'miles', maxCount: 30 });

    expect(await db.tasks.get(ROOT)).toMatchObject({ title: 'Jog 30 miles', action: 'Jog', maxCount: 30, version: 2 });
    expect(await db.tasks.get('c-live')).toMatchObject({
      title: 'Jog 10 miles',
      action: 'Jog',
      unit: 'miles',
      maxCount: 10,
      version: 5,
    });
    await expectUntouched('c-frozen', 'Run 8 miles');
    await expectUntouched('c-sealed', 'Run 7 miles');
    expect(await db.tasks.get('c-deleted')).toMatchObject({ title: 'Run 9 miles', version: 4 });
    expect(await queuedTaskIds()).toEqual(['c-live', ROOT].sort());
  });

  it('a custom root rename carries verbatim to the live copy', async () => {
    await seedFamily();
    await saveTaskEdit(ROOT, { title: 'Marathon block' });
    expect(await db.tasks.get('c-live')).toMatchObject({ title: 'Marathon block', maxCount: 10, version: 5 });
    await expectUntouched('c-frozen', 'Run 8 miles');
  });

  it('a custom copy title is kept when the root title stays auto (unit change still lands)', async () => {
    await seedFamily({}, { title: 'Morning run' });
    await saveTaskEdit(ROOT, { title: 'Run 26 km', unit: 'km' });
    expect(await db.tasks.get('c-live')).toMatchObject({ title: 'Morning run', unit: 'km', version: 5 });
  });

  it('a goal-only edit writes no copy', async () => {
    await seedFamily();
    await saveTaskEdit(ROOT, { title: 'Run 40 miles', maxCount: 40 });
    await expectUntouched('c-live', 'Run 10 miles');
    expect(await queuedTaskIds()).toEqual([ROOT]);
  });

  it('editing a copy (not a root) propagates nothing', async () => {
    await seedFamily();
    await saveTaskEdit('c-live', { title: 'Jog 10 miles', action: 'Jog' });
    expect(await db.tasks.get(ROOT)).toMatchObject({ title: 'Run 26 miles', action: 'Run', version: 1 });
    await expectUntouched('c-sealed', 'Run 7 miles');
    expect(await queuedTaskIds()).toEqual(['c-live']);
  });

  it('a plain task edit propagates nothing', async () => {
    await seedFamily();
    await db.tasks.add(counting('plain', { title: 'Read', type: TaskType.NORMAL, action: undefined, unit: undefined, maxCount: undefined }));
    await saveTaskEdit('plain', { title: 'Read more' });
    await expectUntouched('c-live', 'Run 10 miles');
    expect(await queuedTaskIds()).toEqual(['plain']);
  });

  it('kind switch + action change in one save: one authored write per copy carrying both', async () => {
    await seedFamily(
      { title: 'Run 26.2 miles', maxCount: 26.2, countKind: 'continuous' },
      { title: 'Run 10.5 miles', maxCount: 10.5, countKind: 'continuous' },
    );
    await saveTaskEdit(ROOT, { countKind: 'discrete', title: 'Jog 26 miles', action: 'Jog', maxCount: 26 });

    expect(await db.tasks.get('c-live')).toMatchObject({
      countKind: 'discrete',
      maxCount: 11,
      title: 'Jog 11 miles',
      action: 'Jog',
      version: 5,
    });
    const items = (await db.syncQueue.toArray()).filter((i) => i.entityId === 'c-live');
    expect(items).toHaveLength(1);
    expect(JSON.parse(items[0].payload as string)).toMatchObject({ title: 'Jog 11 miles', countKind: 'discrete', version: 5 });
  });
});
