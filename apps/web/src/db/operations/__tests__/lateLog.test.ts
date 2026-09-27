import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  lateLogCompletion,
  lateLogIncrement,
  lateLogCompoundParts,
  previewLateLogCompoundRule,
  LateLogError,
} from '../lateLog';
import { sealBoard } from '../sealing';

/**
 * Board Edit redesign slice 4 (T2, D7/D9) — direct late log on a CLOSED
 * board's own play surface. Covers the R1 owner-ruling scenario end to end
 * (ran Tuesday, forgot to log, logs Friday for the Tuesday board — counts
 * for Tuesday + every containing open/sealed window, never Friday) plus the
 * per-task-type branches.
 */

const USER = 'user-1';

// A Tuesday daily: 07-01 (Tue). Sealed the next day (auto-close deadline is
// end of the NEXT daily window — D4).
const DAILY_START = '2026-07-01T00:00:00.000Z';
const DAILY_END = '2026-07-01T23:59:59.999Z';
const DAILY_SEALED_AT = '2026-07-02T00:00:01.000Z';

// A still-open weekly containing the Tuesday (07-01), e.g. Mon 06-29 – Sun 07-05.
const WEEKLY_START = '2026-06-29T00:00:00.000Z';
const WEEKLY_END = '2026-07-05T23:59:59.999Z';

// A sealed monthly whose window also contains the Tuesday.
const MONTHLY_START = '2026-07-01T00:00:00.000Z';
const MONTHLY_END = '2026-07-31T23:59:59.999Z';
const MONTHLY_SEALED_AT = '2026-08-02T00:00:01.000Z';

// "Friday" — when the user actually logs it.
const FRIDAY_NOW = '2026-07-04T18:00:00.000Z';

const DAILY = 'daily-board';
const WEEKLY = 'weekly-board';
const MONTHLY = 'monthly-board';
const TASK = 'run-task';

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

async function seedNormalTask(id: string): Promise<Task> {
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
  return task;
}

async function seedCountingTask(id: string, maxCount: number, over: Partial<Task> = {}): Promise<Task> {
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
  return task;
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

async function eventsFor(taskId: string): Promise<TaskEvent[]> {
  return db.taskEvents.where('taskId').equals(taskId).toArray();
}

/** Seeds the R1 three-board fixture (Tuesday daily / open weekly / sealed monthly). */
async function seedR1Fixture(taskId: string): Promise<void> {
  await seedBoard(DAILY, { id: DAILY, timeframe: Timeframe.DAILY, startDate: DAILY_START, endDate: DAILY_END });
  await placeTask(DAILY, taskId, 0);
  await sealBoard(DAILY, DAILY_SEALED_AT);

  await seedBoard(WEEKLY, {
    id: WEEKLY,
    timeframe: Timeframe.WEEKLY,
    startDate: WEEKLY_START,
    endDate: WEEKLY_END,
  });
  await placeTask(WEEKLY, taskId, 0);

  await seedBoard(MONTHLY, {
    id: MONTHLY,
    timeframe: Timeframe.MONTHLY,
    startDate: MONTHLY_START,
    endDate: MONTHLY_END,
  });
  await placeTask(MONTHLY, taskId, 0);
  await sealBoard(MONTHLY, MONTHLY_SEALED_AT);
}

// ─── R1 end-to-end scenario ─────────────────────────────────────────────────

describe('R1 scenario — late-logging a counting task on a closed Tuesday daily from Friday', () => {
  it('stamps ONE event at the daily endDate, re-derives D + M, live-cascades W, in one transaction', async () => {
    await seedCountingTask(TASK, 5);
    await seedR1Fixture(TASK);

    await lateLogIncrement(DAILY, TASK, 5, FRIDAY_NOW);

    const events = await eventsFor(TASK);
    expect(events).toHaveLength(1);
    expect(events[0].occurredAt).toBe(new Date(DAILY_END).toISOString());
    expect(events[0].boardId).toBe(DAILY);
    expect(events[0].createdAt).toBe(FRIDAY_NOW);

    const daily = await db.boards.get(DAILY);
    expect(daily?.sealedCompletedCells).toEqual([0]);
    expect(daily?.completedTasks).toBe(1);
    // Local-only re-derive: sealed board's version does NOT bump beyond the
    // seal write (no version bump / no enqueue on the re-derive path).
    expect(daily?.version).toBe(2);

    const monthly = await db.boards.get(MONTHLY);
    expect(monthly?.sealedCompletedCells).toEqual([0]);
    expect(monthly?.completedTasks).toBe(1);
    expect(monthly?.version).toBe(2); // seal write only, re-derive is local-only

    const weekly = await db.boards.get(WEEKLY);
    expect(weekly?.completedTasks).toBe(1); // live cascade picked it up

    // Lifetime cache updated too.
    const stored = await db.tasks.get(TASK);
    expect(stored?.currentCount).toBe(5);

    // The scenario names a Friday daily — that board must be untouched: no
    // board for Friday was even seeded, and the event's occurredAt proves it
    // can never resolve into a Friday window.
  });

  it('a guard failure (unknown task on a valid closed board) writes nothing', async () => {
    await seedCountingTask(TASK, 5);
    await seedR1Fixture(TASK);

    // Force a failure deep in the transaction by deleting the board between
    // the guard check and the write — simulate via an invalid task id after
    // the fact is awkward, so instead assert the invariant a different way:
    // an unknown task id inside a valid closed board throws before ANY write.
    await expect(lateLogIncrement(DAILY, 'not-a-real-task', 5, FRIDAY_NOW)).rejects.toBeInstanceOf(
      LateLogError,
    );
    expect(await eventsFor(TASK)).toHaveLength(0);
    expect((await db.boards.get(DAILY))?.version).toBe(2); // only the seal write
  });
});

describe('R1 scenario — variant: CLOSED weekly, OPEN monthly, a Friday daily', () => {
  it('Tuesday + closed weekly + open monthly + lifetime get +5; the Friday daily does not', async () => {
    const LATER_NOW = '2026-07-07T10:00:00.000Z'; // after the weekly closed
    const FRIDAY_DAILY = 'friday-daily';
    await seedCountingTask(TASK, 5);
    await seedBoard(DAILY, { timeframe: Timeframe.DAILY, startDate: DAILY_START, endDate: DAILY_END });
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);
    await seedBoard(WEEKLY, { timeframe: Timeframe.WEEKLY, startDate: WEEKLY_START, endDate: WEEKLY_END });
    await placeTask(WEEKLY, TASK, 0);
    await sealBoard(WEEKLY, '2026-07-06T00:00:01.000Z');
    await seedBoard(MONTHLY, { timeframe: Timeframe.MONTHLY, startDate: MONTHLY_START, endDate: MONTHLY_END });
    await placeTask(MONTHLY, TASK, 0);
    await seedBoard(FRIDAY_DAILY, {
      timeframe: Timeframe.DAILY,
      startDate: '2026-07-03T00:00:00.000Z',
      endDate: '2026-07-03T23:59:59.999Z',
    });
    await placeTask(FRIDAY_DAILY, TASK, 0);

    await lateLogIncrement(DAILY, TASK, 5, LATER_NOW);

    const events = await eventsFor(TASK);
    expect(events).toHaveLength(1);
    expect(events[0].occurredAt).toBe(new Date(DAILY_END).toISOString());
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([0]);
    const weekly = await db.boards.get(WEEKLY);
    expect(weekly?.sealedCompletedCells).toEqual([0]);
    expect(weekly?.version).toBe(2); // seal write only — sealed re-derive is local-only
    expect((await db.boards.get(MONTHLY))?.completedTasks).toBe(1);
    expect((await db.boards.get(FRIDAY_DAILY))?.completedTasks).toBe(0);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(5);
  });

  it('rolls back the event, caches and every board if a sealed re-derive throws mid-transaction', async () => {
    await seedCountingTask(TASK, 5);
    await seedR1Fixture(TASK);
    const original = db.boards.update.bind(db.boards);
    const spy = vi.spyOn(db.boards, 'update').mockImplementation(((key: string, changes: object) =>
      key === MONTHLY ? Promise.reject(new Error('boom')) : original(key, changes)) as typeof db.boards.update);
    try {
      await expect(lateLogIncrement(DAILY, TASK, 5, FRIDAY_NOW)).rejects.toThrow('boom');
    } finally {
      spy.mockRestore();
    }
    expect(await eventsFor(TASK)).toHaveLength(0);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(0);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([]);
    expect((await db.boards.get(WEEKLY))?.completedTasks).toBe(0);
  });
});

// ─── lateLogCompletion (NORMAL) ─────────────────────────────────────────────

describe('lateLogCompletion', () => {
  it('appends a completion stamped at endDate and re-derives the closed board green', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogCompletion(DAILY, TASK, FRIDAY_NOW);

    const events = await eventsFor(TASK);
    expect(events).toHaveLength(1);
    expect(events[0].kind).toBe('completion');
    expect(events[0].occurredAt).toBe(new Date(DAILY_END).toISOString());

    const board = await db.boards.get(DAILY);
    expect(board?.sealedCompletedCells).toEqual([0]);
  });

  it('is a no-op when the square is already green inside the sealed window', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await db.taskEvents.add({
      id: 'existing',
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

    await lateLogCompletion(DAILY, TASK, FRIDAY_NOW);

    expect(await eventsFor(TASK)).toHaveLength(1); // no second event
  });

  it('throws on an unsealed (open) board', async () => {
    await seedNormalTask(TASK);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await expect(lateLogCompletion(DAILY, TASK, FRIDAY_NOW)).rejects.toBeInstanceOf(LateLogError);
  });

  it('throws for a non-NORMAL task', async () => {
    await seedCountingTask(TASK, 5);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);
    await expect(lateLogCompletion(DAILY, TASK, FRIDAY_NOW)).rejects.toBeInstanceOf(LateLogError);
  });
});

// ─── lateLogIncrement (COUNTING) ────────────────────────────────────────────

describe('lateLogIncrement', () => {
  it('allows partial progress (no completion) and overshoot (never high-clamped)', async () => {
    await seedCountingTask(TASK, 5);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogIncrement(DAILY, TASK, 2, FRIDAY_NOW);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([]);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(2);

    await lateLogIncrement(DAILY, TASK, 10, FRIDAY_NOW);
    expect((await db.tasks.get(TASK))?.currentCount).toBe(12); // overshoot kept
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([0]);
  });

  it('window-stamped derived counter: the event lands on the ROOT, frozen row gets no write, sealed board still re-derives green', async () => {
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

    // The event authored on the ROOT, never the derived row.
    expect(await eventsFor(ROOT)).toHaveLength(1);
    expect(await eventsFor(DERIVED)).toHaveLength(0);

    const derivedRow = await db.tasks.get(DERIVED);
    // The derived row's OWN lifetime fields are untouched — it's never authored.
    expect(derivedRow?.currentCount).toBe(0);

    const board = await db.boards.get(DAILY);
    expect(board?.sealedCompletedCells).toEqual([0]); // re-derived from the root's in-window events
  });

  it('hub-linked derived counter (no startDate) is a no-op (OQ2)', async () => {
    const ROOT = 'root-hub';
    const LINKED = 'linked-hub';
    await seedCountingTask(ROOT, 10);
    await seedCountingTask(LINKED, 5, { sharedCounterId: ROOT });
    await seedBoard(DAILY);
    await placeTask(DAILY, LINKED, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogIncrement(DAILY, LINKED, 3, FRIDAY_NOW);

    expect(await eventsFor(ROOT)).toHaveLength(0);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([]);
  });

  it('throws on an unsealed board', async () => {
    await seedCountingTask(TASK, 5);
    await seedBoard(DAILY);
    await placeTask(DAILY, TASK, 0);
    await expect(lateLogIncrement(DAILY, TASK, 1, FRIDAY_NOW)).rejects.toBeInstanceOf(LateLogError);
  });

  it('rejects a non-positive-integer delta', async () => {
    await seedCountingTask(TASK, 5);
    await seedBoard(DAILY);
    await sealBoard(DAILY, DAILY_SEALED_AT);
    await expect(lateLogIncrement(DAILY, TASK, 0, FRIDAY_NOW)).rejects.toThrow();
    await expect(lateLogIncrement(DAILY, TASK, -1, FRIDAY_NOW)).rejects.toThrow();
  });
});

// ─── lateLogCompoundParts (COMPOUND) ────────────────────────────────────────

describe('lateLogCompoundParts', () => {
  async function seedCompound(): Promise<{ compoundId: string; normalChildId: string; countingChildId: string }> {
    const compoundId = 'compound-1';
    const normalChildId = 'child-normal';
    const countingChildId = 'child-counting';
    await seedNormalTask(normalChildId);
    await seedCountingTask(countingChildId, 3);
    const compound: Task = {
      id: compoundId,
      userId: USER,
      title: 'Morning routine',
      type: TaskType.COMPOUND,
      operator: OperatorType.AND,
      isCompleted: false,
      totalCompletions: 0,
      totalInstances: 1,
      createdAt: DAILY_START,
      updatedAt: DAILY_START,
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(compound);
    const links: CompoundChild[] = [
      {
        id: 'link-1',
        compoundTaskId: compoundId,
        childTaskId: normalChildId,
        childIndex: 0,
        createdAt: DAILY_START,
        updatedAt: DAILY_START,
        version: 1,
        isDeleted: false,
      },
      {
        id: 'link-2',
        compoundTaskId: compoundId,
        childTaskId: countingChildId,
        childIndex: 1,
        createdAt: DAILY_START,
        updatedAt: DAILY_START,
        version: 1,
        isDeleted: false,
      },
    ];
    for (const link of links) await db.compoundChildren.add(link);
    return { compoundId, normalChildId, countingChildId };
  }

  it('commits one completion per staged NORMAL child and one increment per staged COUNTING child, re-deriving the parent', async () => {
    const { compoundId, normalChildId, countingChildId } = await seedCompound();
    await seedBoard(DAILY);
    await placeTask(DAILY, compoundId, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await lateLogCompoundParts(
      DAILY,
      compoundId,
      [
        { childTaskId: normalChildId, kind: 'completion' },
        { childTaskId: countingChildId, kind: 'increment', delta: 3 },
      ],
      FRIDAY_NOW,
    );

    expect(await eventsFor(normalChildId)).toHaveLength(1);
    expect(await eventsFor(countingChildId)).toHaveLength(1);
    const board = await db.boards.get(DAILY);
    expect(board?.sealedCompletedCells).toEqual([0]); // AND(both children) satisfied
  });

  it('ignores an action for a task that is not actually a child of the compound', async () => {
    const { compoundId } = await seedCompound();
    await seedNormalTask('not-a-child');
    await seedBoard(DAILY);
    await placeTask(DAILY, compoundId, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    // The foreign action is dropped, leaving AND unmet — rejected, nothing written.
    await expect(
      lateLogCompoundParts(DAILY, compoundId, [{ childTaskId: 'not-a-child', kind: 'completion' }], FRIDAY_NOW),
    ).rejects.toMatchObject({ kind: 'ruleNotMet' });

    expect(await eventsFor('not-a-child')).toHaveLength(0);
  });

  it('rejects (ruleNotMet) and writes nothing when the staged parts do not meet the rule', async () => {
    const { compoundId, normalChildId, countingChildId } = await seedCompound();
    await seedBoard(DAILY);
    await placeTask(DAILY, compoundId, 0);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    await expect(
      lateLogCompoundParts(DAILY, compoundId, [{ childTaskId: normalChildId, kind: 'completion' }], FRIDAY_NOW),
    ).rejects.toMatchObject({ kind: 'ruleNotMet' });
    expect(await eventsFor(normalChildId)).toHaveLength(0);
    expect(await eventsFor(countingChildId)).toHaveLength(0);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([]);
  });

  it('preview: a staged +1 that finishes a 2/3 counting child meets AND; a prior-window increment never counts', async () => {
    const { compoundId, normalChildId, countingChildId } = await seedCompound();
    await seedBoard(DAILY);
    await placeTask(DAILY, compoundId, 0);
    const base = { taskId: countingChildId, userId: USER, kind: 'increment' as const, isDeleted: false, version: 1 };
    await db.taskEvents.bulkAdd([
      // Two in-window, one in a PREVIOUS window (must be ignored).
      { ...base, id: 'in-1', delta: 2, occurredAt: '2026-07-01T08:00:00.000Z', createdAt: DAILY_START, updatedAt: DAILY_START },
      { ...base, id: 'prev-1', delta: 5, occurredAt: '2026-06-30T08:00:00.000Z', createdAt: DAILY_START, updatedAt: DAILY_START },
    ]);
    await sealBoard(DAILY, DAILY_SEALED_AT);

    const normalOnly = [{ childTaskId: normalChildId, kind: 'completion' as const }];
    const both = [...normalOnly, { childTaskId: countingChildId, kind: 'increment' as const, delta: 1 }];
    expect(await previewLateLogCompoundRule(DAILY, compoundId, normalOnly)).toBe(false);
    expect(await previewLateLogCompoundRule(DAILY, compoundId, both)).toBe(true);

    await lateLogCompoundParts(DAILY, compoundId, both, FRIDAY_NOW);
    expect((await db.boards.get(DAILY))?.sealedCompletedCells).toEqual([0]);
  });

  it('throws on an unsealed board', async () => {
    const { compoundId, normalChildId } = await seedCompound();
    await seedBoard(DAILY);
    await placeTask(DAILY, compoundId, 0);
    await expect(
      lateLogCompoundParts(DAILY, compoundId, [{ childTaskId: normalChildId, kind: 'completion' }], FRIDAY_NOW),
    ).rejects.toBeInstanceOf(LateLogError);
  });
});
