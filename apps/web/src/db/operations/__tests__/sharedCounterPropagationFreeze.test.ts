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
import * as orchestration from '../orchestration';
import {
  decrementSharedCounter,
  incrementSharedCounter,
  undoLastCounterLog,
} from '../tasks.sharedCounter';

/**
 * Propagation freeze (docs/WINDOWED_COMPLETION.md §Derived-task carve-out,
 * docs/BOARD_SOURCES.md §Plan B2 notes, audit 2026-09-23 finding #1).
 *
 * A shared-counter increment / decrement / undo must NOT write, enqueue or
 * cascade a window-stamped derived row whose window has ended — it touches
 * only the rows whose windows are still open (plus hub-linked rows, which
 * have no window). And the board cascade runs ONCE for the whole changed set.
 *
 * The clock is pinned (Date only) so "ended" vs "in-window" is deterministic.
 */

const USER = 'user-1';
const NOW = '2026-09-23T12:00:00.000Z';
const SEEDED = '2026-09-01T08:00:00.000Z';

const ROOT = 'root-1';
const LIVE = 'derived-live'; // current week, in-window
const ENDED = 'derived-ended'; // last week, window ended before NOW
const HUB = 'hub-linked'; // no startDate → not window-stamped, never frozen

const BOARD_LIVE = 'board-live';
const BOARD_ENDED = 'board-ended';

function root(): Task {
  return {
    id: ROOT,
    userId: USER,
    title: 'Run 100 km',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'km',
    maxCount: 100,
    currentCount: 2,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
  } as Task;
}

function derived(id: string, over: Partial<Task>): Task {
  return {
    id,
    userId: USER,
    title: 'Run 3 km',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'km',
    maxCount: 3,
    sharedCounterId: ROOT,
    baseline: 0,
    currentCount: 2,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdInWizard: true,
    timeframe: Timeframe.WEEKLY,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 4,
    isDeleted: false,
    ...over,
  } as Task;
}

async function seedBoard(id: string, startDate: string, endDate: string): Promise<void> {
  const board: Board = {
    id,
    userId: USER,
    name: id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    startDate,
    endDate,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: SEEDED,
    updatedAt: SEEDED,
    version: 1,
    isDeleted: false,
  };
  await db.boards.add(board);
}

async function seedPlacement(id: string, boardId: string, taskId: string): Promise<void> {
  const bt: BoardTask = {
    id,
    boardId,
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

async function seed(): Promise<void> {
  await db.tasks.add(root());
  await db.tasks.add(
    derived(LIVE, { startDate: '2026-09-21T00:00:00.000Z', endDate: '2026-09-27T23:59:59.999Z' }),
  );
  await db.tasks.add(
    derived(ENDED, { startDate: '2026-09-14T00:00:00.000Z', endDate: '2026-09-20T23:59:59.999Z' }),
  );
  // Hub-linked: an endDate in the past but no startDate → never frozen.
  await db.tasks.add(
    derived(HUB, { createdInWizard: false, startDate: undefined, endDate: '2026-09-20T23:59:59.999Z' }),
  );
  await seedBoard(BOARD_LIVE, '2026-09-21T00:00:00.000Z', '2026-09-27T23:59:59.999Z');
  // An unsealed, still-ACTIVE past-window board: frozen regardless (the
  // kernel handles its completion from events; the fan-out bound is the point).
  await seedBoard(BOARD_ENDED, '2026-09-14T00:00:00.000Z', '2026-09-20T23:59:59.999Z');
  await seedPlacement('bt-live', BOARD_LIVE, LIVE);
  await seedPlacement('bt-ended', BOARD_ENDED, ENDED);
}

async function queuedIds(entityType: string): Promise<string[]> {
  return (await db.syncQueue.toArray())
    .filter((i) => i.entityType === entityType)
    .map((i) => i.entityId);
}

/** The ended row and its board must be byte-for-byte what `seed()` wrote. */
async function expectEndedUntouched(): Promise<void> {
  const ended = await db.tasks.get(ENDED);
  expect(ended!.version).toBe(4);
  expect(ended!.currentCount).toBe(2);
  expect(ended!.isCompleted).toBe(false);
  expect(ended!.completedAt).toBeUndefined();
  expect(ended!.updatedAt).toBe(SEEDED);
  expect(await queuedIds('tasks')).not.toContain(ENDED);
  // No cascade reached the ended row's board either.
  expect((await db.boards.get(BOARD_ENDED))!.version).toBe(1);
  expect(await queuedIds('boards')).not.toContain(BOARD_ENDED);
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date(NOW));
  await seed();
});

afterEach(async () => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  await Promise.all([
    db.tasks.clear(),
    db.taskEvents.clear(),
    db.boards.clear(),
    db.boardTasks.clear(),
    db.compoundChildren.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('shared-counter propagation freeze', () => {
  it('increment writes + enqueues the in-window and hub-linked rows, skips the ended row', async () => {
    const { affectedBoards } = await incrementSharedCounter(ROOT, 1);

    const live = await db.tasks.get(LIVE);
    expect(live!.version).toBe(5);
    expect(live!.currentCount).toBe(3);
    expect(live!.isCompleted).toBe(true);
    expect(live!.completedAt).toBe(NOW);

    const hub = await db.tasks.get(HUB);
    expect(hub!.version).toBe(5);
    expect(hub!.currentCount).toBe(3);

    const queuedTasks = await queuedIds('tasks');
    expect(queuedTasks).toEqual(expect.arrayContaining([ROOT, LIVE, HUB]));
    await expectEndedUntouched();

    // Credit comes from the unfrozen set only.
    expect(affectedBoards.map((b) => b.boardId)).toEqual([BOARD_LIVE]);
    // The live board was cascaded (stats recomputed + enqueued).
    expect((await db.boards.get(BOARD_LIVE))!.version).toBe(2);
    expect(await queuedIds('boards')).toContain(BOARD_LIVE);
  });

  it('decrement skips the ended row', async () => {
    const { affectedBoards, effectiveDelta } = await decrementSharedCounter(ROOT, 1);
    expect(effectiveDelta).toBe(1);
    const live = await db.tasks.get(LIVE);
    expect(live!.version).toBe(5);
    expect(live!.currentCount).toBe(1);
    await expectEndedUntouched();
    expect(affectedBoards.map((b) => b.boardId)).toEqual([BOARD_LIVE]);
  });

  it('undo skips the ended row', async () => {
    await incrementSharedCounter(ROOT, 1);
    const { undoneAmount, affectedBoards } = await undoLastCounterLog(ROOT);
    expect(undoneAmount).toBe(1);
    const live = await db.tasks.get(LIVE);
    expect(live!.version).toBe(6);
    expect(live!.currentCount).toBe(2);
    await expectEndedUntouched();
    expect(affectedBoards.map((b) => b.boardId)).toEqual([BOARD_LIVE]);
  });

  it('runs ONE batched board cascade over the source + unfrozen rows', async () => {
    const batched = vi.spyOn(orchestration, 'runBoardCascadeForTasks');
    const single = vi.spyOn(orchestration, 'runBoardCascadeForTask');

    await incrementSharedCounter(ROOT, 1);

    expect(batched).toHaveBeenCalledTimes(1);
    expect(single).not.toHaveBeenCalled();
    const ids = [...(batched.mock.calls[0][0] as Iterable<string>)];
    expect(ids.sort()).toEqual([HUB, LIVE, ROOT].sort());
  });
});
