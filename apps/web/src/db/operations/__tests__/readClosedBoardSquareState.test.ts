import { afterEach, describe, expect, it } from 'vitest';
import { BoardStatus, CenterSquareType, TaskType, Timeframe, type Board, type BoardTask, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { lateLogCompletion, lateLogIncrement, readClosedBoardSquareState } from '../lateLog';
import { sealBoard } from '../sealing';

/**
 * Board Edit redesign slice 4 (T3, D15/D16) — the late-log sheet's read
 * model. Exercises the REAL `readClosedBoardSquareState` against the same
 * fixtures as `lateLog.test.ts`.
 */

const USER = 'user-1';
const DAILY_START = '2026-07-01T00:00:00.000Z';
const DAILY_END = '2026-07-01T23:59:59.999Z';
const DAILY_SEALED_AT = '2026-07-02T00:00:01.000Z';
const FRIDAY_NOW = '2026-07-04T18:00:00.000Z';
const DAILY = 'daily-board';
const TASK = 'task-1';

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedNormalTask(id: string): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title: 'N',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: DAILY_START,
    updatedAt: DAILY_START,
    version: 1,
    isDeleted: false,
  };
  await db.tasks.add(task);
}

async function seedCountingTask(id: string, maxCount: number, over: Partial<Task> = {}): Promise<void> {
  const task: Task = {
    id,
    userId: USER,
    title: 'C',
    type: TaskType.COUNTING,
    maxCount,
    action: 'Run',
    unit: 'mi',
    isCompleted: false,
    currentCount: 0,
    totalCompletions: 0,
    totalInstances: 1,
    createdAt: DAILY_START,
    updatedAt: DAILY_START,
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.tasks.add(task);
}

async function seedBoard(id: string, over: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id,
    userId: USER,
    name: 'B',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.DAILY,
    startDate: DAILY_START,
    endDate: DAILY_END,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: DAILY_START,
    updatedAt: DAILY_START,
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.boards.put(board);
  return board;
}

async function placeTask(boardId: string, taskId: string, cell: number): Promise<void> {
  const bt: BoardTask = {
    id: `bt-${boardId}-${taskId}`,
    boardId,
    taskId,
    row: Math.floor(cell / 3),
    col: cell % 3,
    isCenter: false,
    createdAt: DAILY_START,
    updatedAt: DAILY_START,
    version: 1,
    isDeleted: false,
  };
  await db.boardTasks.add(bt);
}

describe('readClosedBoardSquareState — NORMAL', () => {
  it('grey before a late log, green + one undoable late log after', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    const before = await readClosedBoardSquareState(DAILY, TASK);
    expect(before).toMatchObject({ isGreen: false, lateLogs: [] });

    await lateLogCompletion(DAILY, TASK, FRIDAY_NOW);

    const after = await readClosedBoardSquareState(DAILY, TASK);
    expect(after?.isGreen).toBe(true);
    expect(after?.lateLogs).toHaveLength(1);
    expect(after?.effectiveTaskId).toBe(TASK);
  });

  it('returns null for an open (unsealed) board', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    expect(await readClosedBoardSquareState(DAILY, TASK)).toBeNull();
  });
});

describe('readClosedBoardSquareState — COUNTING', () => {
  it('reports the sealed-bounded windowed count, not the lifetime cache (D16)', async () => {
    await seedCountingTask(TASK, 5);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogIncrement(DAILY, TASK, 3, FRIDAY_NOW);
    const state = await readClosedBoardSquareState(DAILY, TASK);
    expect(state?.count).toBe(3);
    expect(state?.isGreen).toBe(false);

    await lateLogIncrement(DAILY, TASK, 5, FRIDAY_NOW); // overshoot
    const overshoot = await readClosedBoardSquareState(DAILY, TASK);
    expect(overshoot?.count).toBe(8);
    expect(overshoot?.isGreen).toBe(true);
  });

  it('resolves a window-stamped derived square to the ROOT for late logs + count', async () => {
    const ROOT = 'root';
    const DERIVED = 'derived';
    await seedCountingTask(ROOT, 10);
    await seedCountingTask(DERIVED, 5, {
      sharedCounterId: ROOT,
      startDate: DAILY_START,
      endDate: DAILY_END,
      createdInWizard: true,
      baseline: 0,
    });
    await seedBoard(DAILY);
    await placeTask(DAILY, DERIVED, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogIncrement(DAILY, DERIVED, 5, FRIDAY_NOW);
    const state = await readClosedBoardSquareState(DAILY, DERIVED);
    expect(state?.effectiveTaskId).toBe(ROOT);
    expect(state?.count).toBe(5);
    expect(state?.isGreen).toBe(true);
    expect(state?.lateLogs).toHaveLength(1);
  });

  it('returns null for a hub-linked derived counter (OQ2 — not tappable)', async () => {
    const ROOT = 'root-hub';
    const LINKED = 'linked-hub';
    await seedCountingTask(ROOT, 10);
    await seedCountingTask(LINKED, 5, { sharedCounterId: ROOT });
    await seedBoard(DAILY);
    await placeTask(DAILY, LINKED, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    expect(await readClosedBoardSquareState(DAILY, LINKED)).toBeNull();
  });
});
