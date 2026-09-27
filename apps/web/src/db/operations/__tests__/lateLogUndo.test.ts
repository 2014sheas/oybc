import { afterEach, describe, expect, it } from 'vitest';
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
import { lateLogCompletion, lateLogIncrement, undoLateLog } from '../lateLog';
import { sealBoard } from '../sealing';
import { tombstoneLatestCompletion } from '../taskEvents';

/**
 * Board Edit redesign slice 4 (T2, D10 / owner ruling R2) — undo of a
 * closed-board late log, identified by provenance (`boardId` + `occurredAt`
 * == the board's `endDate`, `createdAt > sealedAt`), never a marker field.
 * All other sealed-window events stay tombstone-immune.
 */

const USER = 'user-1';
const DAILY_START = '2026-07-01T00:00:00.000Z';
const DAILY_END = '2026-07-01T23:59:59.999Z';
const DAILY_SEALED_AT = '2026-07-02T00:00:01.000Z';
const FRIDAY_NOW = '2026-07-04T18:00:00.000Z';
const DAILY = 'daily-board';
const TASK = 'run-task';

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
    title: 'Run',
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
    title: 'Run',
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

describe('undoLateLog — NORMAL (completion)', () => {
  it('tombstones the late-logged completion and re-derives the board back to grey', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogCompletion(DAILY, TASK, FRIDAY_NOW);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([0]);

    const undone = await undoLateLog(DAILY, TASK, '2026-07-05T00:00:00.000Z');
    expect(undone).toBe(true);

    const board = await db.boards.get(DAILY);
    expect(board?.sealedCompletedCells).toEqual([]);
    const events = await db.taskEvents.where('taskId').equals(TASK).toArray();
    expect(events.every((e) => e.isDeleted)).toBe(true);
  });

  it('returns false — no-op — when there is no late log to undo', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    expect(await undoLateLog(DAILY, TASK, '2026-07-05T00:00:00.000Z')).toBe(false);
  });

  it('an in-window pre-seal event stays immune — undo never touches it', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    // A normal in-window completion, made BEFORE the seal (not a late log).
    await db.taskEvents.add({
      id: 'pre-seal',
      userId: USER,
      taskId: TASK,
      kind: 'completion',
      occurredAt: '2026-07-01T08:00:00.000Z',
      createdAt: '2026-07-01T08:00:00.000Z',
      updatedAt: '2026-07-01T08:00:00.000Z',
      version: 1,
      isDeleted: false,
    });
    await sealBoard(DAILY, DAILY_SEALED_AT);

    expect(await undoLateLog(DAILY, TASK, '2026-07-05T00:00:00.000Z')).toBe(false);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([0]); // untouched
    // The generic tombstone path also refuses it (seal-immune).
    await tombstoneLatestCompletion(TASK, '2026-07-05T00:00:00.000Z');
    const events = await db.taskEvents.where('taskId').equals(TASK).toArray();
    expect(events.find((e) => e.id === 'pre-seal')?.isDeleted).toBe(false);
  });

  it('a repeated "Mark done on board" tap is idempotent (one completion, one undoable log)', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogCompletion(DAILY, TASK, '2026-07-03T00:00:00.000Z');
    await lateLogCompletion(DAILY, TASK, '2026-07-04T00:00:00.000Z'); // already green — no-op

    const first = await undoLateLog(DAILY, TASK, '2026-07-05T00:00:00.000Z');
    expect(first).toBe(true);
    const second = await undoLateLog(DAILY, TASK, '2026-07-05T00:00:00.000Z');
    expect(second).toBe(false); // nothing left to undo
  });

  it('a late log becomes immune again once a containing board seals AFTER it was made', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogCompletion(DAILY, TASK, FRIDAY_NOW);

    // A containing weekly seals AFTER the late log was created — it
    // re-freezes the event: undo must refuse it now.
    const WEEKLY = 'weekly-board';
    await seedBoard(WEEKLY, {
      timeframe: Timeframe.WEEKLY,
      startDate: '2026-06-29T00:00:00.000Z',
      endDate: '2026-07-05T23:59:59.999Z',
    });
    await placeTask(WEEKLY, TASK, 0);
    await sealBoard(WEEKLY, '2026-07-10T00:00:00.000Z'); // after FRIDAY_NOW

    expect(await undoLateLog(DAILY, TASK, '2026-07-11T00:00:00.000Z')).toBe(false);
  });
});

describe('undoLateLog — COUNTING (increment), one at a time', () => {
  it('two separate late-logged increments undo newest-first, one per call', async () => {
    await seedCountingTask(TASK, 10);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogIncrement(DAILY, TASK, 3, '2026-07-03T00:00:00.000Z');
    await lateLogIncrement(DAILY, TASK, 2, '2026-07-04T00:00:00.000Z');
    expect((await db.tasks.get(TASK))?.currentCount).toBe(5);

    expect(await undoLateLog(DAILY, TASK, '2026-07-05T00:00:00.000Z')).toBe(true);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(3); // reversed the +2

    expect(await undoLateLog(DAILY, TASK, '2026-07-05T00:01:00.000Z')).toBe(true);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(0); // reversed the +3

    expect(await undoLateLog(DAILY, TASK, '2026-07-05T00:02:00.000Z')).toBe(false); // nothing left
  });
});

describe('undoLateLog — COUNTING (increment)', () => {
  it('subtracts the reversed delta from the lifetime currentCount and re-derives', async () => {
    await seedCountingTask(TASK, 5);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogIncrement(DAILY, TASK, 5, FRIDAY_NOW);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(5);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([0]);

    const undone = await undoLateLog(DAILY, TASK, '2026-07-05T00:00:00.000Z');
    expect(undone).toBe(true);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(0);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([]);
  });

  it('window-stamped derived square: undo resolves to the ROOT and re-derives the containing board', async () => {
    const ROOT = 'root-counter';
    const DERIVED = 'derived-row';
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
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([0]);

    // Undo is called with the DERIVED square's id (what the UI has in hand) —
    // it must resolve to the root's late log internally.
    const undone = await undoLateLog(DAILY, DERIVED, '2026-07-05T00:00:00.000Z');
    expect(undone).toBe(true);
    expect((await db.tasks.get(ROOT))?.currentCount).toBe(0);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([]);
  });
});

describe('R4 recovery — a log stamped on the wrong day', () => {
  it('undo the hub/library log made on Friday, then late-log it on the Tuesday board', async () => {
    await seedCountingTask(TASK, 5);
    const DAILY_TUE = 'tuesday-board';
    await seedBoard(DAILY_TUE);
    await placeTask(DAILY_TUE, TASK, 0);
    await sealBoard(DAILY_TUE, DAILY_SEALED_AT);

    // The user mistakenly logged it from the hub on Friday — a plain event
    // with no boardId, stamped `now` (Friday), not the Tuesday board's endDate.
    await db.taskEvents.add({
      id: 'wrong-day',
      userId: USER,
      taskId: TASK,
      kind: 'increment',
      delta: 5,
      occurredAt: FRIDAY_NOW,
      createdAt: FRIDAY_NOW,
      updatedAt: FRIDAY_NOW,
      version: 1,
      isDeleted: false,
    });
    await db.tasks.update(TASK, { currentCount: 5 });

    // Recovery step 1: undo the wrong-day entry via the generic counter-log
    // undo (not a late-log undo — it wasn't made on the closed board).
    const { undoLastCounterLog } = await import('../tasks.sharedCounter');
    const { undoneAmount } = await undoLastCounterLog(TASK);
    expect(undoneAmount).toBe(5);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(0);

    // Recovery step 2: late-log it on the Tuesday board instead.
    await lateLogIncrement(DAILY_TUE, TASK, 5, '2026-07-05T00:00:00.000Z');
    expect((await db.tasks.get(TASK))?.currentCount).toBe(5);
    expect((await db.boards.get(DAILY_TUE))?.sealedCompletedCells).toEqual([0]);
  });
});
